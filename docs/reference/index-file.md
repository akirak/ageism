# Index file

When `--index-out-dir` is given, `ageism` writes `<index-out-dir>/<host>.json` for each target host. It maps the base name of each secret (without `.age`) to its deployed filename in `/var/lib/ageism`:

```json
{
  "wifi-password": "sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.a1b2c3d4.age",
  "ssh-host-key": "sha256-ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb.a1b2c3d4.age"
}
```

## Deployed filename

```text
sha256-<sha256>.<ID>.age
```

- `<sha256>` is the SHA-256 hash of the source secret file. A change to the source therefore produces a new filename.
- `<ID>` is the first 8 hex characters of the SHA-256 digest of the host's encrypted `identity.age`. The secret can be decrypted with `identity.<ID>` in the same directory.

Commit the index files alongside your NixOS configuration and read them with `builtins.fromJSON` to set the `source` of each secret in the [NixOS module](../guide/nixos-module).
