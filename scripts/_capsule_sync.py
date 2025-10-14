#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import stat
import struct
import sys
from collections import defaultdict, deque
from typing import Dict, List, NamedTuple, Optional, Sequence, Set, Tuple


class BinarySpec(NamedTuple):
    candidates: Tuple[str, ...]
    required: bool = True


BINARY_SPECS: Sequence[BinarySpec] = (
    BinarySpec(("system/bin/servicemanager",)),
    BinarySpec(("system/bin/hwservicemanager",)),
    BinarySpec(("system/bin/property_service", "system/bin/bootstrap/property_service"), False),
)

CONFIG_FILES: Sequence[Tuple[str, bool]] = (
    ("system/etc/ld.config.txt", False),
    ("system/etc/ld.config.version.txt", False),
    ("apex/com.android.runtime/etc/ld.config.txt", False),
)

CONFIG_DIRS: Sequence[str] = (
    "system/etc/selinux",
)


def posix_path(path: str) -> str:
    return path.replace(os.sep, "/")


def parse_elf_metadata(path: str) -> Dict[str, Optional[Sequence[str]]]:
    with open(path, "rb") as handle:
        data = handle.read()
    if len(data) < 16 or data[:4] != b"\x7fELF":
        raise ValueError(f"{path} is not a valid ELF binary")

    elf_class = data[4]
    if elf_class == 1:
        is_64 = False
    elif elf_class == 2:
        is_64 = True
    else:
        raise ValueError(f"{path}: unsupported ELF class {elf_class}")

    data_encoding = data[5]
    if data_encoding == 1:
        endian = "<"
    elif data_encoding == 2:
        endian = ">"
    else:
        raise ValueError(f"{path}: unsupported data encoding {data_encoding}")

    if is_64:
        e_phoff = struct.unpack_from(endian + "Q", data, 32)[0]
        e_phentsize = struct.unpack_from(endian + "H", data, 54)[0]
        e_phnum = struct.unpack_from(endian + "H", data, 56)[0]
    else:
        e_phoff = struct.unpack_from(endian + "I", data, 28)[0]
        e_phentsize = struct.unpack_from(endian + "H", data, 42)[0]
        e_phnum = struct.unpack_from(endian + "H", data, 44)[0]

    load_segments: List[Tuple[int, int, int]] = []
    dyn_segment: Optional[Tuple[int, int, int]] = None
    interp: Optional[str] = None

    for idx in range(e_phnum):
        offset = e_phoff + idx * e_phentsize
        if is_64:
            p_type, p_flags = struct.unpack_from(endian + "II", data, offset)
            p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = struct.unpack_from(
                endian + "QQQQQQ", data, offset + 8
            )
        else:
            (
                p_type,
                p_offset,
                p_vaddr,
                p_paddr,
                p_filesz,
                p_memsz,
                p_flags,
                p_align,
            ) = struct.unpack_from(endian + "IIIIIIII", data, offset)

        if p_type == 1:  # PT_LOAD
            load_segments.append((p_vaddr, p_offset, p_filesz))
        elif p_type == 2:  # PT_DYNAMIC
            dyn_segment = (p_offset, p_filesz, p_vaddr)
        elif p_type == 3:  # PT_INTERP
            segment = data[p_offset : p_offset + p_filesz]
            interp = segment.split(b"\x00", 1)[0].decode("utf-8")

    needed_offsets: List[int] = []
    strtab_vaddr: Optional[int] = None
    strtab_size: Optional[int] = None

    if dyn_segment:
        dyn_off, dyn_size, dyn_vaddr = dyn_segment
        entry_size = 16 if is_64 else 8
        for cursor in range(0, dyn_size, entry_size):
            if dyn_off + cursor + entry_size > len(data):
                break
            if is_64:
                d_tag, d_val = struct.unpack_from(endian + "qQ", data, dyn_off + cursor)
            else:
                d_tag, d_val = struct.unpack_from(endian + "iI", data, dyn_off + cursor)
            if d_tag == 0:  # DT_NULL
                break
            if d_tag == 1:  # DT_NEEDED
                needed_offsets.append(d_val)
            elif d_tag == 5:  # DT_STRTAB
                strtab_vaddr = d_val
            elif d_tag == 10:  # DT_STRSZ
                strtab_size = d_val

    def virt_to_file(vaddr: int) -> Optional[int]:
        for seg_vaddr, seg_off, seg_size in load_segments:
            if seg_vaddr <= vaddr < seg_vaddr + seg_size:
                return seg_off + (vaddr - seg_vaddr)
        return None

    needed: List[str] = []
    if strtab_vaddr is not None:
        strtab_off = virt_to_file(strtab_vaddr)
        if strtab_off is None:
            raise RuntimeError(f"{path}: unable to resolve STRTAB offset")
        for rel_offset in needed_offsets:
            start = strtab_off + rel_offset
            if start >= len(data):
                continue
            end = data.find(b"\x00", start)
            if end == -1 or (strtab_size and end >= strtab_off + strtab_size):
                end = start
                while end < len(data) and data[end] != 0:
                    end += 1
            name = data[start:end].decode("utf-8")
            if name:
                needed.append(name)

    return {"needed": needed, "interp": interp}


def build_library_index(root: str) -> Dict[str, str]:
    index: Dict[str, str] = {}
    search_roots: List[str] = []
    lib_dirs = ("lib64", "lib")

    for prefix in ("system", "system_ext", "product", "vendor", "odm"):
        for libdir in lib_dirs:
            candidate = os.path.join(root, prefix, libdir)
            if os.path.isdir(candidate):
                search_roots.append(candidate)

    apex_root = os.path.join(root, "apex")
    if os.path.isdir(apex_root):
        for entry in sorted(os.listdir(apex_root)):
            entry_path = os.path.join(apex_root, entry)
            if not os.path.isdir(entry_path):
                continue
            for libdir in lib_dirs:
                candidate = os.path.join(entry_path, libdir)
                if os.path.isdir(candidate):
                    search_roots.append(candidate)

    for base in search_roots:
        for dirpath, _dirnames, filenames in os.walk(base):
            for filename in filenames:
                if not filename.endswith(".so"):
                    continue
                rel = posix_path(os.path.relpath(os.path.join(dirpath, filename), root))
                index.setdefault(filename, rel)
    return index


def ensure_parent(path: str) -> None:
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    else:
        os.makedirs(path, exist_ok=True)


def resolve_read_path(root: str, rel_path: str) -> str:
    abs_path = os.path.join(root, rel_path)
    try:
        st = os.lstat(abs_path)
    except FileNotFoundError:
        return abs_path
    if stat.S_ISLNK(st.st_mode):
        target = os.readlink(abs_path)
        if target.startswith("/"):
            candidates = [os.path.join(root, target.lstrip("/"))]
            if target.startswith("/apex/"):
                candidates.append(os.path.join(root, "system", target.lstrip("/")))
            elif target.startswith("/system/"):
                candidates.append(os.path.join(root, target.lstrip("/")))
            for candidate in candidates:
                if os.path.exists(candidate):
                    return candidate
    return abs_path


def copy_entry(root: str, dest: str, rel_path: str) -> None:
    src = os.path.join(root, rel_path)
    dst = os.path.join(dest, rel_path)
    ensure_parent(dst)
    if os.path.islink(src):
        target = os.readlink(src)
        if os.path.lexists(dst):
            os.unlink(dst)
        os.symlink(target, dst)
    else:
        shutil.copy2(src, dst)


def copy_config_file(
    root: str,
    dest: str,
    rel_path: str,
    required: bool,
    artifact_types: Dict[str, str],
    source_map: Dict[str, str],
) -> None:
    src = os.path.join(root, rel_path)
    if not os.path.exists(src):
        message = f"Config file '{rel_path}' missing from system image"
        if required:
            raise FileNotFoundError(message)
        print(f"Warning: {message}", file=sys.stderr)
        return
    copy_entry(root, dest, rel_path)
    artifact_types.setdefault(rel_path, "config")
    source_map.setdefault(rel_path, rel_path)


def copy_config_dir(root: str, dest: str, rel_path: str) -> Optional[str]:
    src = os.path.join(root, rel_path)
    if not os.path.isdir(src):
        print(f"Warning: config directory '{rel_path}' missing from system image", file=sys.stderr)
        return None
    dst = os.path.join(dest, rel_path)
    ensure_parent(dst)
    shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)
    return posix_path(rel_path)


def sha256sum(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def sync_artifacts(
    root: str, dest: str
) -> Tuple[Dict[str, str], Dict[str, str], List[str], Set[str], List[str]]:
    root = os.path.abspath(root)
    dest = os.path.abspath(dest)

    os.makedirs(dest, exist_ok=True)

    lib_index = build_library_index(root)
    artifact_types: Dict[str, str] = {}
    source_map: Dict[str, str] = {}
    queue: deque[str] = deque()
    seen: set[str] = set()
    missing_libs: defaultdict[str, List[str]] = defaultdict(list)
    provided_externals: set[str] = set()

    missing_required: List[str] = []
    optional_missing: List[str] = []
    for spec in BINARY_SPECS:
        selected: Optional[str] = None
        for candidate in spec.candidates:
            abs_path = os.path.join(root, candidate)
            if os.path.exists(abs_path) or os.path.islink(abs_path):
                selected = candidate
                break
        if not selected:
            choice = " or ".join(spec.candidates)
            if spec.required:
                missing_required.append(choice)
            else:
                optional_missing.append(choice)
            continue
        queue.append(selected)
        artifact_types[selected] = "binary"
        source_map[selected] = selected

    if missing_required:
        raise FileNotFoundError(
            "Required binaries missing from system image: "
            + ", ".join(sorted(missing_required))
        )

    while queue:
        rel_path = queue.popleft()
        if rel_path in seen:
            continue
        abs_path = resolve_read_path(root, rel_path)
        if not os.path.exists(abs_path):
            provided_externals.add(rel_path)
            artifact_types.pop(rel_path, None)
            source_map.pop(rel_path, None)
            seen.add(rel_path)
            continue
        info = parse_elf_metadata(abs_path)
        interp = info["interp"]
        if interp:
            interp_rel = posix_path(interp.lstrip("/"))
            if interp_rel and interp_rel not in artifact_types:
                interp_abs = os.path.join(root, interp_rel)
                if not os.path.exists(interp_abs):
                    raise FileNotFoundError(
                        f"Interpreter '{interp_rel}' referenced by '{rel_path}' missing from system image"
                    )
                artifact_types[interp_rel] = "interpreter"
                source_map[interp_rel] = interp_rel
                queue.append(interp_rel)
        for lib_name in info["needed"] or []:
            candidate_rel = lib_index.get(lib_name)
            if not candidate_rel:
                missing_libs[rel_path].append(lib_name)
                continue
            candidate_abs = os.path.join(root, candidate_rel)
            if not (os.path.exists(candidate_abs) or os.path.islink(candidate_abs)):
                provided_externals.add(candidate_rel)
                continue
            if candidate_rel not in artifact_types:
                artifact_types[candidate_rel] = "library"
                source_map[candidate_rel] = candidate_rel
                queue.append(candidate_rel)
        seen.add(rel_path)

    if missing_libs:
        lines = ["Unable to resolve shared library dependencies:"]
        for binary, libs in missing_libs.items():
            lines.append(f"  {binary}:")
            for name in libs:
                lines.append(f"    - {name}")
        raise RuntimeError("\n".join(lines))

    for rel in sorted(artifact_types):
        copy_entry(root, dest, rel)

    for rel, required in CONFIG_FILES:
        copy_config_file(root, dest, rel, required, artifact_types, source_map)

    config_dir_prefixes: List[str] = []
    for rel in CONFIG_DIRS:
        prefix = copy_config_dir(root, dest, rel)
        if prefix:
            config_dir_prefixes.append(prefix)

    return artifact_types, source_map, config_dir_prefixes, provided_externals, optional_missing


def write_manifest(
    dest: str,
    manifest_path: str,
    artifact_types: Dict[str, str],
    source_map: Dict[str, str],
    config_dir_prefixes: Sequence[str],
) -> List[Dict[str, str]]:
    artifacts: List[Dict[str, str]] = []
    for dirpath, _dirnames, filenames in os.walk(dest):
        for filename in filenames:
            full_path = os.path.join(dirpath, filename)
            rel_path = posix_path(os.path.relpath(full_path, dest))
            artifact_type = artifact_types.get(rel_path)
            if not artifact_type:
                for prefix in config_dir_prefixes:
                    if rel_path == prefix or rel_path.startswith(prefix + "/"):
                        artifact_type = "config"
                        break
            if not artifact_type:
                artifact_type = "config"
            if os.path.islink(full_path):
                artifacts.append(
                    {
                        "type": "symlink",
                        "path": rel_path,
                        "source": source_map.get(rel_path, rel_path),
                        "target": os.readlink(full_path),
                    }
                )
            else:
                artifacts.append(
                    {
                        "type": artifact_type,
                        "path": rel_path,
                        "source": source_map.get(rel_path, rel_path),
                        "sha256": sha256sum(full_path),
                    }
                )

    artifacts.sort(key=lambda item: item["path"])

    os.makedirs(os.path.dirname(manifest_path), exist_ok=True)
    with open(manifest_path, "w", encoding="utf-8") as handle:
        handle.write("# Generated by scripts/download_emulator_system.sh\n")
        for item in artifacts:
            handle.write("[[artifact]]\n")
            handle.write(f"path = {toml_string(item['path'])}\n")
            handle.write(f"source = {toml_string(item['source'])}\n")
            handle.write(f"type = {toml_string(item['type'])}\n")
            if item["type"] == "symlink":
                handle.write(f"target = {toml_string(item['target'])}\n\n")
            else:
                handle.write(f"sha256 = {toml_string(item['sha256'])}\n\n")

    return artifacts


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Copy core Android services and dependencies into android/capsule/system."
    )
    parser.add_argument("system_root", help="Path to the extracted system root")
    parser.add_argument("destination", help="Output directory (android/capsule/system)")
    parser.add_argument("manifest", help="Manifest path to generate (android/capsule/manifest.toml)")
    args = parser.parse_args()

    system_root = os.path.abspath(args.system_root)
    destination = os.path.abspath(args.destination)
    manifest_path = os.path.abspath(args.manifest)

    (
        artifact_types,
        source_map,
        config_dir_prefixes,
        provided_externals,
        optional_missing,
    ) = sync_artifacts(system_root, destination)
    artifacts = write_manifest(destination, manifest_path, artifact_types, source_map, config_dir_prefixes)

    summary: defaultdict[str, int] = defaultdict(int)
    for item in artifacts:
        summary[item["type"]] += 1

    print(f"Wrote manifest for {len(artifacts)} artifacts.", file=sys.stderr)
    for key in sorted(summary):
        print(f"  {key}: {summary[key]}", file=sys.stderr)

    if optional_missing:
        for rel in optional_missing:
            print(f"Warning: optional binary '{rel}' not found in system image.", file=sys.stderr)
    if provided_externals:
        for rel in sorted(provided_externals):
            print(f"Info: dependency '{rel}' not copied (provided by base system/apex).", file=sys.stderr)


if __name__ == "__main__":
    main()
