# How it works

A deployment runs through the following phases.

## 1. Discovery and hashing

`ageism` scans `--secrets-root/<host>` for `*.age` files, following symlinks, and computes the SHA-256 hash of each dereferenced source file. `identity.age` is reserved for the host's encrypted identity and is never deployed as a secret.

## 2. Inspection

It lists the target's destination directory (`/var/lib/ageism` by default, or `--install-dir`) to find secrets that are already deployed (files with a `sha256-` prefix) and identities (`identity.<ID>`).

## 3. Decryption

The host identity (if missing on the target) and any missing secrets are decrypted locally with `age --decrypt`. Secrets shared between hosts are decrypted only once and kept in an in-memory cache for the rest of the run.

## 4. Encryption and transfer

For each target host, concurrently:

- The decrypted identity is written to `identity.<ID>` with `0600` permissions, unless a file with the same ID already exists. `ID` is the first 8 hex characters of the SHA-256 digest of the **encrypted** `identity.age`.
- Plaintexts are encrypted to the host's recipient with `age --encrypt`.
- The re-encrypted ciphertexts are transferred and written as `sha256-<sha256>.<ID>.age` with `0600` permissions.

Remote hosts are reached through a single multiplexed SSH connection to `root@<host>`, shared by the inspection and all transfers. Localhost is handled through a persistent elevated shell (`sudo` or `run0`).

A failure on one host is reported but does not stop deployment to the other hosts.

## 5. Index output

If `--index-out-dir` is given, `<index-out-dir>/<host>.json` is written, mapping each secret name to its deployed filename. See [Index file](../reference/index-file).

## Identity rotation

Because each identity is stored under an ID derived from its encrypted file, replacing `identity.age` installs a new `identity.<ID>` alongside the old one. Existing identities are never re-transferred or removed, so secrets encrypted to an older identity remain decryptable.

## At boot

On the target, each `*.<ID>.age` secret is decrypted with the matching `identity.<ID>`. The [NixOS module](./nixos-module) provides a systemd service that does this.
