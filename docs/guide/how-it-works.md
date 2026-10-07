# How it works

The diagram shows how a secret moves from the repository to a running service when `ageism` is used with the [NixOS module](./nixos-module).

```mermaid
flowchart LR
  subgraph client["Client"]
    subgraph repo["Repository: secrets/HOST/"]
      src["*.age encrypted to you"]
    end
    subgraph mem["Memory"]
      tmp["plaintext"]
    end
  end
  subgraph target["Deployment target"]
    subgraph lib["/var/lib/ageism/"]
      dep["*.age encrypted to the host"]
    end
    subgraph run["/run/ageism/"]
      plain["plaintext files"]
    end
  end
  src -- "decrypt" --> tmp
  tmp -- "re-encrypt and transfer" --> dep
  dep -- "decrypt" --> plain
```

1. On the client, `ageism` decrypts the secrets in the repository. The plaintext is only held in memory.
2. `ageism` re-encrypts the plaintext to the host's key and transfers the result to `/var/lib/ageism` on the target.
3. On the target, `ageism-secrets.service` from the NixOS module decrypts the secrets into the paths declared in `services.ageism.secrets`, such as files under `/run/ageism`.
4. Services read the plaintext files directly or through [systemd credentials](./systemd-credentials).

The rest of this page describes each phase of a deployment.

## 1. Discovery and hashing

`ageism` scans `--secrets-root/<host>` for `*.age` files, following symlinks, and computes the SHA-256 hash of each dereferenced source file. With `--recursive`, subdirectories are scanned recursively, retaining the directory structure on the target. `identity.age` is reserved for the host's encrypted identity and is never deployed as a secret.

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

Because each identity is stored under an ID derived from its encrypted file, replacing `identity.age` installs a new `identity.<ID>` alongside the old one. Existing identities are never re-transferred, so secrets encrypted to an older identity remain decryptable.

Deployed files are not removed by default. With `--prune`, `ageism` removes secrets that are no longer in the host's secrets directory, along with identities that no remaining secret uses. Secrets already deployed under an older identity keep using it, so its `identity.<ID>` is kept until they are gone. Pruned files are removed before you activate the new NixOS configuration, so a reboot into the previous generation in between cannot decrypt secrets that were removed.

## At boot

On the target, each `*.<ID>.age` secret is decrypted with the matching `identity.<ID>`. The [NixOS module](./nixos-module) provides a systemd service that does this.
