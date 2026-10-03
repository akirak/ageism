# ageism

Ageism is an `age` secret deployment tool for NixOS.

Documentation: <https://akirak.github.io/ageism/>

`ageism` manages and deploys encrypted secrets to target hosts (both localhost and remote machines over SSH). It handles secret rekeying, deduplication, incremental deployment, and secret indexing for NixOS configurations.

---

## Features

- **Age Rekeying on Deploy**: Decrypts source `.age` secrets on the deployment controller and re-encrypts them on the fly for each target host's specific public key.
- **Concurrent & Resilient Deployment**: Uses [Eio](https://github.com/ocaml-multicore/eio) to prepare and deploy to multiple hosts concurrently. Failure on one target does not block deployment to others.
- **Deduplication & Decryption Caching**: Caches decrypted secrets by SHA-256 hash in memory during a deploy run; secrets shared across multiple hosts (e.g. via symlinks) are only decrypted once.
- **Incremental Deployment**: Identifies secrets on the target by content hash; only missing or changed secrets are transferred.
- **Secure Shell Transfer**: Uploads encrypted payloads to remote hosts over a single multiplexed SSH connection (checks and file transfers share the connection), and through a persistent elevated shell (`sudo` or `run0`) for localhost, with strict `0600` permissions.
- **Per-Host Identities**: Each host's directory may contain an encrypted `identity.age`; it is decrypted on the controller and installed on the target as `/var/lib/ageism/identity.<ID>` (root-only), where `ID` is the first 8 hex characters of the SHA-256 digest of the encrypted file. Identities already present are not re-transferred, so old identities remain available for secrets encrypted to them.
- **Index Generation**: Optionally generates JSON index files mapping secret basenames to their deployed filenames (`<name>.age -> sha256-<sha256>.<ID>.age`) for NixOS consumption.
- **NixOS Install Support**: Deploy directly into a mounted filesystem root via `--install-dir` during `nixos-install`.

---

## How It Works

1. **Discovery & Hashing**:
   `ageism` scans `--secrets-root/<host>` for `*.age` files (following symlinks) and computes the SHA-256 hash of each dereferenced source file. The name `identity.age` is reserved for the host's encrypted identity and is never deployed as a secret.
2. **Inspection**:
   It queries the target's destination directory (`/var/lib/ageism` by default, or `--install-dir`) to list already deployed secrets (identified by `sha256-`-prefixed names) and identities (`identity.<ID>`).
3. **Decryption Phase**:
   The host identity (if missing on the target) and any missing secrets are decrypted using local `age --decrypt`. Shared secrets across different target hosts are decrypted only once and held in an in-memory cache.
4. **Encryption & Transfer Phase**:
   For each target host concurrently:
   - The decrypted identity is written to `identity.<ID>` with `0600` file permissions, unless a file with the same ID already exists. `ID` is the first 8 hex characters of the SHA-256 digest of the *encrypted* `identity.age`.
   - Plaintexts are encrypted with the host's recipient key using `age --encrypt`.
   - Re-encrypted ciphertexts are transferred and written to the destination directory as `sha256-<sha256>.<ID>.age` with `0600` file permissions.
5. **Index Output**:
   If `--index-out-dir` is provided, a JSON file (`<index-out-dir>/<host>.json`) is created mapping secret names to their deployed filenames.

At boot time the target scans its `identity.*` files and decrypts each `*.<ID>.age` secret with the matching identity.

---

## Requirements

### External Binaries

`ageism` invokes the following CLI tools:

- [`age`](https://github.com/FiloSottile/age) (for encryption and decryption)
- `ssh` (when targeting remote hosts)
- `sudo` or `run0` (when deploying to localhost)

### OCaml Environment

- OCaml `>= 5.2`
- [Dune](https://dune.build/) `>= 3.23`
- OPAM dependencies: `eio`, `eio_main`, `cmdliner`, `yojson`, `ppx_yojson_conv`, `digestif`

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
| `--secrets-root=DIR` | **Required.** Root directory containing per-host secrets directories. |
| `-i`, `--identity=FILE` | **Required.** Path to an age identity file (private key) used to decrypt source secrets on the controller. |
| `--recipient-file=FILE` | Path to an age recipient file (public key) to use for encryption. |
| `--recipient-dir=DIR` | Directory containing recipient files named `<HOSTNAME>.txt`. |
| `--index-out-dir=DIR` | Output directory where `<HOSTNAME>.json` secret index maps will be written. |
| `--install-dir=DIR` | Destination directory on localhost (e.g. `/mnt/var/lib/ageism` during `nixos-install`). Defaults to `/var/lib/ageism`. |
| `--elevation=STRATEGY` | Privilege elevation strategy for localhost (`sudo` or `run0`). Defaults to `sudo`. |
| `--age=EXE` | The `age` executable used for decryption and rekeying. Defaults to `age` (looked up in `PATH`). |
| `--help` | Show command line reference and help. |
| `--version` | Show version information. |

> **Note:** Either `--recipient-file` or `--recipient-dir` must be specified.

### Environment Variables

Every option can also be configured via an environment variable. Command line options take precedence; environment variables are used only as a fallback.

| Environment variable | Option |
|---|---|
| `AGEISM_SECRETS_ROOT` | `--secrets-root` |
| `AGEISM_IDENTITY_FILE` | `-i`, `--identity` |
| `AGEISM_RECIPIENT_FILE` | `--recipient-file` |
| `AGEISM_RECIPIENT_DIR` | `--recipient-dir` |
| `AGEISM_INDEX_OUT_DIR` | `--index-out-dir` |
| `AGEISM_INSTALL_DIR` | `--install-dir` |
| `AGEISM_ELEVATION` | `--elevation` |
| `AGEISM_AGE` | `--age` |

---

## Examples

### Directory Structure

A typical repository layout:

```text
secrets/
├── common/
│   └── wifi-password.age
├── host1/
│   ├── identity.age
│   ├── wifi-password.age -> ../common/wifi-password.age
│   └── ssh-host-key.age
└── host2/
    ├── identity.age
    ├── wifi-password.age -> ../common/wifi-password.age
    └── wireguard-key.age

recipients/
├── host1.txt
└── host2.txt
```

Each `identity.age` is the host's age identity (private key) encrypted like any other secret in the repository. A host with secrets but no `identity.age` cannot be deployed to.

### Deploy to Multiple Remote Hosts

Deploy secrets to `host1` and `host2` over SSH:

```bash
ageism \
  --secrets-root=./secrets \
  --recipient-dir=./recipients \
  --index-out-dir=./indices \
  host1 host2
```

### Deploy to Localhost

Deploy secrets to the local machine (`/var/lib/ageism`) using `sudo`:

```bash
ageism \
  --secrets-root=./secrets \
  --recipient-file=./recipients/localhost.txt \
  --index-out-dir=./indices
```

Using `systemd-run0` for elevation:

```bash
ageism \
  --elevation=run0 \
  --secrets-root=./secrets \
  --recipient-file=./recipients/localhost.txt
```

### Deploy During `nixos-install`

When installing NixOS to a mounted root at `/mnt`:

```bash
ageism \
  --secrets-root=./secrets \
  --recipient-file=./recipients/new-machine.txt \
  --install-dir=/mnt/var/lib/ageism
```

### Index File Format

When `--index-out-dir` is specified, `ageism` outputs a JSON file for each target host mapping the secret base name to its stored hashed filename, suffixed with the ID of the host identity that can decrypt it:

```json
{
  "wifi-password": "sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.a1b2c3d4.age",
  "ssh-host-key": "sha256-ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb.a1b2c3d4.age"
}
```

## Inspirations

- [agenix-rekey](https://github.com/oddlama/agenix-rekey)
