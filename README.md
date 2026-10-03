# ageism

Ageism is an `age` secret deployment tool for NixOS.

`ageism` manages and deploys encrypted secrets to target hosts (both localhost and remote machines over SSH). It handles secret rekeying, deduplication, incremental deployment, and secret indexing for NixOS configurations.

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
