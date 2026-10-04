# Getting started

## Lay out your secrets

`ageism` expects a secrets root containing one directory per host. A typical repository looks like this:

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

- Every `*.age` file in `secrets/<host>/` is a secret for that host. Symlinks are followed, so a secret can be shared between hosts.
- All source secrets are encrypted to the controller's age identity, which you pass with `--identity`.
- `identity.age` is reserved. It is the host's own age identity (private key), encrypted like any other secret. A host with secrets but no `identity.age` cannot be deployed to.
- `recipients/<host>.txt` contains the host's age recipient (public key), i.e. the public half of the identity in `identity.age`.

See [Generating a host key](./generating-a-key) to create these two files with `age`, `rage`, or a YubiKey.

## Deploy to remote hosts

Pass host names as positional arguments to deploy over SSH. `ageism` connects as `root@<host>`.

```bash
ageism \
  --identity=~/.config/age/key.txt \
  --secrets-root=./secrets \
  --recipient-dir=./recipients \
  --index-out-dir=./indices \
  host1 host2
```

Secrets are written to `/var/lib/ageism` on each host, and `indices/host1.json` and `indices/host2.json` are generated.

## Deploy to localhost

Without host arguments, `ageism` deploys to the local machine using `sudo`:

```bash
ageism \
  --identity=~/.config/age/key.txt \
  --secrets-root=./secrets \
  --recipient-file=./recipients/localhost.txt \
  --index-out-dir=./indices
```

To use `run0` from systemd instead:

```bash
ageism \
  --elevation=run0 \
  --identity=~/.config/age/key.txt \
  --secrets-root=./secrets \
  --recipient-file=./recipients/localhost.txt
```

## Deploy during `nixos-install`

When installing NixOS to a root mounted at `/mnt`, point `--install-dir` at the target's secret directory:

```bash
ageism \
  --identity=~/.config/age/key.txt \
  --secrets-root=./secrets \
  --recipient-file=./recipients/new-machine.txt \
  --install-dir=/mnt/var/lib/ageism
```

## Avoid repeating options

Every option can be set with an environment variable, which is convenient in a project shell (e.g. with direnv):

```bash
export AGEISM_IDENTITY_FILE=~/.config/age/key.txt
export AGEISM_SECRETS_ROOT=./secrets
export AGEISM_RECIPIENT_DIR=./recipients
export AGEISM_INDEX_OUT_DIR=./indices

ageism host1 host2
```

See the [CLI reference](../reference/cli) for the full list.

## Next steps

- Learn [how deployment works](./how-it-works).
- Decrypt the deployed secrets at boot with the [NixOS module](./nixos-module).
