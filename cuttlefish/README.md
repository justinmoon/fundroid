# Cuttlefish Nix Flake

This directory contains all cuttlefish-related Nix packages, modules, and tooling consolidated into a single flake.

## Documentation

- **[CUTTLEFISH_README.md](docs/CUTTLEFISH_README.md)** - Overview and quick links
- **[AOSP_BUILD.md](docs/AOSP_BUILD.md)** - Building custom cuttlefish from AOSP sources

## Structure

```
cuttlefish/
├── flake.nix              # Main flake exporting packages and modules
├── cfctl/                 # Rust CLI tool for managing cuttlefish instances
├── packages/              # Nix package definitions
│   ├── cfctl.nix         # cfctl package
│   ├── cuttlefish-from-tarball.nix
│   ├── cuttlefish-from-deb.nix
│   ├── cuttlefish-fhs.nix
│   ├── aosp-host.nix     # AOSP host builder
│   ├── aosp-cuttlefish.nix
│   └── cuttlefish-module.nix
├── modules/               # NixOS modules
│   └── cuttlefish-module.nix
├── configs/               # Configuration files
│   └── config_phone_no_radios.json
└── examples/              # Example configurations
    └── tracks.nix
```

## Usage

### As a Flake Input

Add to your `flake.nix`:

```nix
{
  inputs = {
    cuttlefish.url = "github:yourorg/yourrepo?dir=cuttlefish";
    # Or for local development:
    # cuttlefish.url = "path:./cuttlefish";
  };

  outputs = { self, nixpkgs, cuttlefish, ... }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      modules = [
        cuttlefish.nixosModules.cuttlefish
        {
          services.cuttlefish = {
            enable = true;
            defaultTrack = "stock";
            tracks.stock = {
              bundle = pkgs.mkCuttlefishFromTarball {
                url = "https://example.com/cvd-host_package.tar.gz";
                sha256 = "...";
                version = "aosp-14085914";
              };
            };
          };
        }
      ];
    };
  };
}
```

### Building cfctl

```bash
# From this directory
nix build .#cfctl

# From the parent repo
nix build .#cfctl

# On Hetzner (after deployment)
nix build github:yourorg/yourrepo?dir=cuttlefish#cfctl
```

### Available Packages

- `cfctl` - CLI and daemon for managing cuttlefish instances
- `mkCuttlefishFromTarball` - Function to build cuttlefish from tarball
- `mkCuttlefishFromDeb` - Function to build cuttlefish from .deb files
- `mkCuttlefishFHS` - Function to create FHS wrapper for cuttlefish
- `aosp-host` - AOSP host package builder (requires AOSP checkout)

### NixOS Modules

- `cuttlefish` - Full cuttlefish service with multi-track support

See `examples/tracks.nix` for a complete multi-track configuration example.

## Deployment Workflow

1. **Make changes** in this repo (on a feature branch)
2. **Push the branch** to GitHub
3. **Update `~/configs/flake.nix`** to reference the new commit/branch:
   ```nix
   cuttlefish.url = "github:yourorg/yourrepo?ref=your-feature-branch&dir=cuttlefish";
   ```
4. **Deploy to Hetzner**:
   ```bash
   cd ~/configs
   just hetzner
   ```

This workflow ensures all changes are tracked in a single repo and deployed atomically.

## Development

```bash
# Enter development shell
nix develop

# Check flake
nix flake check

# Show flake outputs
nix flake show

# Build and test locally
cd cfctl
cargo build
cargo test
```
