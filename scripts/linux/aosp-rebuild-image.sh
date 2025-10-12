#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AOSP_ROOT="${AOSP_ROOT:-${PROJECT_ROOT}/out/aosp}"
LUNCH_COMBO="${AOSP_LUNCH_COMBO:-webos_cf_x86_64-userdebug}"
JOBS="${AOSP_JOBS:-$(command -v nproc >/dev/null 2>&1 && nproc || echo 8)}"
OVERLAY_SOURCE="${AOSP_OVERLAY_SRC:-${PROJECT_ROOT}/vendor/webos}"
OVERLAY_TARGET="${AOSP_OVERLAY_DST:-${AOSP_ROOT}/vendor/webos}"

if [ ! -d "${AOSP_ROOT}" ]; then
  echo "error: AOSP tree not found at ${AOSP_ROOT}. Run scripts/linux/aosp-bootstrap.sh first." >&2
  exit 1
fi

cd "${AOSP_ROOT}"

if [ ! -f build/envsetup.sh ]; then
  echo "error: build/envsetup.sh missing. Is this an AOSP checkout?" >&2
  exit 1
fi

if [ ! -d "${OVERLAY_SOURCE}" ]; then
  echo "error: overlay source not found at ${OVERLAY_SOURCE}" >&2
  exit 1
fi

echo "Syncing overlay from ${OVERLAY_SOURCE} -> ${OVERLAY_TARGET}" >&2
rsync -a --delete "${OVERLAY_SOURCE}/" "${OVERLAY_TARGET}/"

host_tools_path="${AOSP_ROOT}/prebuilts/build-tools/path/linux-x86"
if [ -n "${AOSP_OUT_SUFFIX:-}" ]; then
  export OUT_DIR="${AOSP_ROOT}/out/${AOSP_OUT_SUFFIX}"
elif [ -n "${AOSP_OUT_DIR:-}" ]; then
  export OUT_DIR="${AOSP_OUT_DIR}"
fi

if [ -n "${OUT_DIR:-}" ]; then
  mkdir -p "${OUT_DIR}"
  export OUT_DIR_COMMON_BASE="$(dirname "${OUT_DIR}")"
fi

shim_dir="${OUT_DIR}/webos-host-tools/bin"
mkdir -p "${shim_dir}"

cat >"${shim_dir}/cmp" <<'EOF'
#!/usr/bin/env python3
import filecmp
import sys

def main(argv: list[str]) -> int:
    quiet = False
    files: list[str] = []

    for arg in argv[1:]:
        if arg in ("-s", "--quiet"):
            quiet = True
        else:
            files.append(arg)

    if len(files) != 2:
        sys.stderr.write("cmp replacement expects exactly two file arguments\n")
        return 2

    same = filecmp.cmp(files[0], files[1], shallow=False)
    if same:
        return 0

    if not quiet:
        sys.stderr.write(f"{files[0]} {files[1]} differ\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
EOF
chmod +x "${shim_dir}/cmp"

cat >"${shim_dir}/mv" <<'EOF'
#!/usr/bin/env python3
import os
import shutil
import sys

def main(argv: list[str]) -> int:
    force = False
    files: list[str] = []

    for arg in argv[1:]:
        if arg in ("-f", "--force"):
            force = True
        else:
            files.append(arg)

    if len(files) != 2:
        sys.stderr.write("mv replacement expects source and destination\n")
        return 2

    src, dst = files

    if os.path.isdir(dst):
        dst = os.path.join(dst, os.path.basename(src))

    if os.path.exists(dst):
        if not force:
            sys.stderr.write(f"mv: cannot overwrite '{dst}'\n")
            return 1
        os.remove(dst)

    shutil.move(src, dst)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
EOF
chmod +x "${shim_dir}/mv"

set +u
set +o posix 2>/dev/null || true
if ! type complete >/dev/null 2>&1; then
  complete() { return 0; }
fi
source build/envsetup.sh

if command -v cmp >/dev/null 2>&1; then
  cmp_dir="$(dirname "$(command -v cmp)")"
  export ANDROID_BUILD_PATHS="${ANDROID_BUILD_PATHS}:${cmp_dir}"
  PATH="${cmp_dir}:${PATH}"
fi

if command -v mv >/dev/null 2>&1; then
  mv_dir="$(dirname "$(command -v mv)")"
  export ANDROID_BUILD_PATHS="${ANDROID_BUILD_PATHS}:${mv_dir}"
  PATH="${mv_dir}:${PATH}"
fi

export ANDROID_BUILD_PATHS="${ANDROID_BUILD_PATHS}:${shim_dir}"
PATH="${shim_dir}:${PATH}"

lunch "${LUNCH_COMBO}"

if command -v cmp >/dev/null 2>&1; then
  cmp_dir="$(dirname "$(command -v cmp)")"
  export ANDROID_BUILD_PATHS="${ANDROID_BUILD_PATHS}:${cmp_dir}"
  PATH="${cmp_dir}:${PATH}"
fi

if command -v mv >/dev/null 2>&1; then
  mv_dir="$(dirname "$(command -v mv)")"
  export ANDROID_BUILD_PATHS="${ANDROID_BUILD_PATHS}:${mv_dir}"
  PATH="${mv_dir}:${PATH}"
fi

export ANDROID_BUILD_PATHS="${ANDROID_BUILD_PATHS}:${shim_dir}"
PATH="${shim_dir}:${PATH}"
set -u
m installclean
m -j"${JOBS}" dist
