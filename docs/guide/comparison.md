# Comparison with agenix-rekey

ageism was inspired by [agenix-rekey](https://github.com/oddlama/agenix-rekey), an extension for [agenix](https://github.com/ryantm/agenix). Both keep the secrets in your repository encrypted to a single master identity and rekey them for each host. They differ in where the rekeyed secrets go and how they reach the host.

agenix-rekey makes the rekeyed secrets part of the system configuration, either committed to the repository or built into the Nix store. They reach the host with the system closure. ageism keeps them out of both. The `ageism` command transfers them to `/var/lib/ageism` on the host in a step separate from `nixos-rebuild`. The NixOS configuration only refers to their content-hash filenames, through the committed [index files](../reference/index-file).

## At a glance

| | ageism | agenix-rekey (`local`) | agenix-rekey (`derivation`) |
|---|---|---|---|
| Source secrets | `secrets/<host>/*.age`, encrypted to the master identity | `*.age` files referenced by `rekeyFile`, encrypted to the master identities | Same as `local` |
| Which secrets a host gets | Every `*.age` in its directory, shared via symlinks | Inferred from `age.secrets` in its configuration | Same as `local` |
| Host key | A dedicated age identity, stored as `identity.age` and installed by ageism | `age.rekey.hostPubkey`, usually the SSH host key | Same as `local` |
| Rekeyed secrets live in | `/var/lib/ageism` on the host only | The repository (`localStorageDir`) | The Nix store |
| Delivery to the host | `ageism` over SSH (or `sudo`/`run0` for localhost) | The system closure | The system closure |
| Building needs the master key | No | No | Yes, or the derivation must be uploaded |
| Stale rekeyed secrets | Detected by content hash on the next `ageism` run | The build fails and asks you to run `agenix rekey` | Same as `local` |
| Decryption on the host | `ageism-decrypt.service`, a oneshot unit | agenix, during activation | Same as `local` |
| Secret generators | No | Yes | Yes |
| Editing helpers | No, use `age` directly | `agenix edit`, `agenix view` | Same as `local` |
| Platforms | NixOS | NixOS, nix-darwin | NixOS, nix-darwin |

## What they share

- **A single master identity.** You only ever encrypt to your own identity. Neither tool needs a `secrets.nix` file listing which host keys may decrypt which secret.
- **Rekeying for each host.** Secrets are decrypted with the master identity on your machine and re-encrypted to the host's public key.
- **Rekeying only what changed.** agenix-rekey caches rekeyed secrets. ageism compares content hashes with what is already on the host and decrypts shared secrets once per run.

## Where they differ

### Storage of rekeyed secrets

agenix-rekey has two storage modes:

- **`local`** commits the rekeyed secrets to your repository. Building stays pure and works without the master key, e.g. in CI. If the repository is public and a host key leaks, an attacker can decrypt every secret ever rekeyed for that host, including those in git history.
- **`derivation`** builds the rekeyed secrets into the Nix store and never commits them. It needs `nix.settings.extra-sandbox-paths` for the rekey cache, a nixpkgs shared with your hosts so the store paths match, and `forceRekeyOnSystem` for hosts of another architecture. A system can only be built where the derivation has been built with the master key, or uploaded to.

ageism avoids both trade-offs. Rekeyed secrets are never in the repository or the Nix store, and building the system needs neither the master key nor the rekeyed secrets. The index files contain only filenames.

Old rekeyed secrets and identities stay in `/var/lib/ageism` until you deploy with `--prune` (see [Identity rotation](./how-it-works#identity-rotation)).

### Deployment

With agenix-rekey, any deployment tool that copies the system closure delivers the secrets.

ageism adds a deployment step. Run `ageism` to transfer the secrets and update the index files, then rebuild. Remote hosts must accept SSH as `root`. Nothing checks at build time that the index files match the deployed secrets. If you rebuild with an index entry that was never deployed, `ageism-decrypt.service` fails on the host.

In exchange, `ageism` deploys to several hosts concurrently with a single SSH connection each. A failure on one host does not stop the others.

### Host keys and bootstrapping

agenix-rekey rekeys to an existing public key, typically the host's SSH key. For a new host whose key is not yet known, it can rekey to a dummy key, so the first boot has no working secrets until the real key is set and the secrets are rekeyed.

ageism manages its own age identity for each host. You generate it, keep it encrypted as `secrets/<host>/identity.age`, and `ageism` installs it with the secrets. A host can therefore receive working secrets before its first boot, e.g. with `--install-dir` during `nixos-install`. The identity is independent of the SSH host key, and replacing `identity.age` keeps the old identity on the host, so secrets encrypted to it still decrypt (see [Identity rotation](./how-it-works#identity-rotation)).

### Decryption on the host

agenix-rekey relies on agenix, which decrypts secrets during system activation into a new generation under `/run/agenix.d` and points `/run/agenix` at it. Secrets are available to activation scripts and replaced on every switch.

ageism decrypts in `ageism-decrypt.service`, a oneshot unit started by `multi-user.target`. Order consumers after it (see [systemd credentials](./systemd-credentials#ordering)). Secrets are not available during activation. ageism also skips a secret whose `path` already exists, so a changed secret with the same `path` is installed only after the file is removed, e.g. by rebooting when it is under `/run`.

### Features ageism does not have

- **Secret generators.** agenix-rekey can generate missing secrets, such as random passwords or WireGuard keys, with `agenix generate`.
- **Editing helpers.** agenix-rekey provides `agenix edit` and `agenix view`. With ageism, you encrypt and decrypt source secrets with `age` yourself.
- **nix-darwin.** ageism only provides a NixOS module.

## Which one to choose

agenix-rekey may suit you better if:

- You want secrets delivered with the system closure by your existing deployment tool, without an extra step.
- You want secret generators or editing helpers.
- You manage nix-darwin hosts.
- You need secrets during activation.

ageism may suit you better if:

- You do not want rekeyed secrets in your repository or the Nix store.
- You want to build systems, e.g. in CI, without the master key.
- You want hosts to have working secrets from their first boot, without depending on their SSH host keys.
- You can SSH into your hosts as `root`.
