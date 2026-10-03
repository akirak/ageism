# CLI

```text
ageism [OPTION]… [HOST]…
```

Each `HOST` is deployed to over SSH as `root@HOST`. If no `HOST` is given, `ageism` deploys to localhost.

## Options

| Option | Description |
|---|---|
| `--secrets-root=DIR` | **Required.** Root directory containing per-host secret directories. |
| `-i`, `--identity=FILE` | **Required.** age identity file (private key) used to decrypt source secrets on the controller. |
| `--recipient-file=FILE` | age recipient file (public key) used for encryption. |
| `--recipient-dir=DIR` | Directory containing recipient files named `<HOST>.txt`. |
| `--index-out-dir=DIR` | Write the [index file](./index-file) for each host to `DIR/<HOST>.json`. |
| `--install-dir=DIR` | Destination directory on localhost, e.g. `/mnt/var/lib/ageism` during `nixos-install`. Defaults to `/var/lib/ageism`. |
| `--elevation=STRATEGY` | Privilege elevation strategy for localhost: `sudo` or `run0`. Defaults to `sudo`. |
| `--age=EXE` | The `age` executable used for decryption and rekeying. Defaults to `age`, looked up in `PATH`. |
| `--help` | Show the command line reference. |
| `--version` | Show version information. |

Either `--recipient-file` or `--recipient-dir` must be specified. If both are given, `--recipient-file` is used.

## Environment variables

Every option can also be set with an environment variable. Command line options take precedence.

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
