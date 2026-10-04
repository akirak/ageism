# ageism

Ageism is an `age` secret deployment tool for NixOS. It's a simpler alternative to [agenix](https://github.com/ryantm/agenix) and [agenix-rekey](https://github.com/oddlama/agenix-rekey) (see [comparison](https://akirak.github.io/ageism/guide/comparison)) that doesn't have to commit encrypted secrets to the configuration repository. It supports YubiKey via [age-plugin-yubikey](https://github.com/str4d/age-plugin-yubikey/).

`ageism` manages and deploys encrypted secrets to target hosts (both localhost and remote machines over SSH). It handles secret rekeying, deduplication, incremental deployment, and secret indexing for NixOS configurations.

## Installation and Usage

See the [documentation](https://akirak.github.io/ageism/) for installation, usage, and the NixOS module.

## Development

```bash
# Enter the development shell
nix develop

# Build and test
dune build
dune runtest

# Format the code
nix fmt

# Preview the documentation
cd docs && pnpm install && pnpm dev
```
