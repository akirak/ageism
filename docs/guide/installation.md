# Installation

## Requirements

`ageism` invokes the following programs at runtime:

- [`age`](https://github.com/FiloSottile/age), for encryption and decryption
- `ssh`, when deploying to remote hosts
- `sudo` or `run0`, when deploying to localhost

## Nix

The repository is a Nix flake. Run it directly:

```bash
nix run github:akirak/ageism -- --help
```

Or build it:

```bash
nix build github:akirak/ageism
```

The flake also exposes a NixOS module as `nixosModules.default`. See [NixOS module](./nixos-module).

## From source

Building from source requires OCaml `>= 5.2` and Dune `>= 3.23`.

```bash
git clone https://github.com/akirak/ageism.git
cd ageism

# Install the OPAM dependencies
opam install . --deps-only

# Build the executable
dune build

# Run it
dune exec ageism -- --help
```

Inside the repository, `nix develop` provides a development shell with all dependencies, and the `justfile` offers a shortcut:

```bash
just run --help
```
