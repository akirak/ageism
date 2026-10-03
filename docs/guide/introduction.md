# Introduction

`ageism` is an [age](https://github.com/FiloSottile/age) secret deployment tool for NixOS.

It manages encrypted secrets in a repository and deploys them to target hosts, both the local machine and remote machines over SSH. It handles rekeying, deduplication, incremental deployment, and generation of secret indices for NixOS configurations.

## Features

- **Rekeying on deploy**: Decrypts source `.age` secrets on the deployment controller and re-encrypts them on the fly for each target host's public key.
- **Concurrent and resilient deployment**: Prepares and deploys to multiple hosts concurrently. A failure on one target does not block deployment to the others.
- **Deduplication and decryption caching**: Decrypted secrets are cached in memory by SHA-256 hash during a run, so secrets shared across hosts (e.g. via symlinks) are decrypted only once.
- **Incremental deployment**: Secrets on the target are identified by content hash; only missing or changed secrets are transferred.
- **Secure transfer**: Uploads to remote hosts over a single multiplexed SSH connection, and through a persistent elevated shell (`sudo` or `run0`) for localhost. Files are written with `0600` permissions.
- **Per-host identities**: Each host's directory may contain an encrypted `identity.age`, which is installed on the target as a root-only identity file. See [How it works](./how-it-works).
- **Index generation**: Optionally writes JSON files mapping secret names to their deployed filenames for use in NixOS configurations.
- **NixOS install support**: Deploy directly into a mounted filesystem root via `--install-dir` during `nixos-install`.

## Inspirations

- [agenix-rekey](https://github.com/oddlama/agenix-rekey). See [Comparison with agenix-rekey](./comparison).
