# ageism

Ageism is an `age` secret deployment tool for NixOS.

`ageism` manages and deploys encrypted secrets to target hosts (both localhost and remote machines over SSH). It handles secret rekeying, deduplication, incremental deployment, and secret indexing for NixOS configurations.

---

## Features

- **Age Rekeying on Deploy**: Decrypts source `.age` secrets on the deployment controller and re-encrypts them on the fly for each target host's specific public key.
- **Concurrent & Resilient Deployment**: Uses [Eio](https://github.com/ocaml-multicore/eio) to prepare and deploy to multiple hosts concurrently. Failure on one target does not block deployment to others.
- **Deduplication & Decryption Caching**: Caches decrypted secrets by SHA-256 hash in memory during a deploy run; secrets shared across multiple hosts (e.g. via symlinks) are only decrypted once.
- **Incremental Deployment**: Identifies secrets on the target by content hash; only missing or changed secrets are transferred.
- **Secure Shell Transfer**: Uploads encrypted payloads over interactive shell streams (`ssh` for remote hosts, `sudo` or `run0` for localhost) using base64 heredocs with strict `0600` permissions.
- **Index Generation**: Optionally generates JSON index files mapping secret basenames to their content hashes (`<name>.age -> sha256-<sha256>.age`) for NixOS consumption.
- **NixOS Install Support**: Deploy directly into a mounted filesystem root via `--install-dir` during `nixos-install`.

---

## How It Works

1. **Discovery & Hashing**:
   `ageism` scans `--secrets-dir/<host>` for `*.age` files (following symlinks) and computes the SHA-256 hash of each dereferenced source file.
2. **Inspection**:
   It queries the target's destination directory (`/var/lib/ageism` by default, or `--install-dir`) to list already deployed secrets (identified by `sha256-`-prefixed 64-character hex SHA-256 hashes).
3. **Decryption Phase**:
   Any missing secrets are decrypted using local `age --decrypt`. Shared secrets across different target hosts are decrypted only once and held in an in-memory cache.
4. **Encryption & Transfer Phase**:
   For each target host concurrently:
   - Plaintexts are encrypted with the host's recipient key using `age --encrypt`.
   - Re-encrypted ciphertexts are transferred and written to the destination directory under their `sha256-`-prefixed SHA-256 hash with `0600` file permissions.
5. **Index Output**:
   If `--index-out-dir` is provided, a JSON file (`<index-out-dir>/<host>.json`) is created mapping secret names to their deployed filenames.

---

## Requirements

### External Binaries

`ageism` invokes the following CLI tools:

- [`age`](https://github.com/FiloSottile/age) (for encryption and decryption)
- `base64` (on target hosts, for decoding uploaded secrets)
- `ssh` (when targeting remote hosts)
- `sudo` or `run0` (when deploying to localhost)

### OCaml Environment

- OCaml `>= 5.2`
- [Dune](https://dune.build/) `>= 3.23`
- OPAM dependencies: `eio`, `eio_main`, `cmdliner`, `yojson`, `ppx_yojson_conv`, `digestif`, `base64`

---

## Installation & Building

### Using Dune

```bash
# Build the executable
dune build

# Run the test suite
dune runtest

# Run the binary
dune exec ageism -- --help
```

### Using Nix Flakes

This repository includes a `flake.nix` with pre-configured packages and a development shell.

```bash
# Enter development shell
nix develop

# Build package
nix build
```

### Using Just

A `justfile` is provided for convenience:

```bash
just run --help
```

---

## Usage

```text
ageism [OPTION]… [HOST]…
```

If no `HOST` arguments are provided, `ageism` defaults to deploying to `localhost`.

### Command-line Options

| Option | Description |
|---|---|
| `--secrets-dir=DIR` | **Required.** Root directory containing per-host secrets directories. |
| `--recipient-file=FILE` | Path to an age recipient file (public key) to use for encryption. |
| `--recipient-dir=DIR` | Directory containing recipient files named `<HOSTNAME>.txt`. |
| `--index-out-dir=DIR` | Output directory where `<HOSTNAME>.json` secret index maps will be written. |
| `--install-dir=DIR` | Destination directory on localhost (e.g. `/mnt/var/lib/ageism` during `nixos-install`). Defaults to `/var/lib/ageism`. |
| `--elevation=STRATEGY` | Privilege elevation strategy for localhost (`sudo` or `run0`). Defaults to `sudo`. |
| `--help` | Show command line reference and help. |
| `--version` | Show version information. |

> **Note:** Either `--recipient-file` or `--recipient-dir` must be specified.

---

## Examples

### Directory Structure

A typical repository layout:

```text
secrets/
├── common/
│   └── wifi-password.age
├── host1/
│   ├── wifi-password.age -> ../common/wifi-password.age
│   └── ssh-host-key.age
└── host2/
    ├── wifi-password.age -> ../common/wifi-password.age
    └── wireguard-key.age

recipients/
├── host1.txt
└── host2.txt
```

### Deploy to Multiple Remote Hosts

Deploy secrets to `host1` and `host2` over SSH:

```bash
ageism \
  --secrets-dir=./secrets \
  --recipient-dir=./recipients \
  --index-out-dir=./indices \
  host1 host2
```

### Deploy to Localhost

Deploy secrets to the local machine (`/var/lib/ageism`) using `sudo`:

```bash
ageism \
  --secrets-dir=./secrets \
  --recipient-file=./recipients/localhost.txt \
  --index-out-dir=./indices
```

Using `systemd-run0` for elevation:

```bash
ageism \
  --elevation=run0 \
  --secrets-dir=./secrets \
  --recipient-file=./recipients/localhost.txt
```

### Deploy During `nixos-install`

When installing NixOS to a mounted root at `/mnt`:

```bash
ageism \
  --secrets-dir=./secrets \
  --recipient-file=./recipients/new-machine.txt \
  --install-dir=/mnt/var/lib/ageism
```

### Index File Format

When `--index-out-dir` is specified, `ageism` outputs a JSON file for each target host mapping the secret base name to its stored hashed filename:

```json
{
  "wifi-password": "sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.age",
  "ssh-host-key": "sha256-ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb.age"
}
```
