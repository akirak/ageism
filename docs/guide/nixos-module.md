# NixOS module

The flake exports a NixOS module as `nixosModules.default`. It adds a oneshot systemd service, `ageism-secrets`, that decrypts deployed secrets into their final locations at boot (and on reload whenever the secret list changes). Secrets marked `neededForUsers` are decrypted separately by `ageism-secrets-for-users`, which is wanted by and runs before `systemd-sysusers.service`.

## Setup

Add the flake to your inputs and import the module:

```nix
{
  inputs.ageism.url = "github:akirak/ageism";

  outputs = { nixpkgs, ageism, ... }: {
    nixosConfigurations.host1 = nixpkgs.lib.nixosSystem {
      modules = [
        ageism.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

## Declaring secrets

Each entry in `services.ageism.secrets` points at a deployed secret (`source`) and describes where and how the plaintext is installed. The [index file](../reference/index-file) generated with `--index-out-dir` gives you the deployed filename for each secret:

```nix
{ ... }:
let
  index = builtins.fromJSON (builtins.readFile ./indices/host1.json);
  deployed = name: "/var/lib/ageism/${index.${name}}";
in
{
  services.ageism = {
    enable = true;

    secrets = {
      wifi-password = {
        source = deployed "wifi-password";
        path = "/run/ageism/wifi-password";
        owner = "root";
        mode = "0400";
      };

      ssh-host-key = {
        source = deployed "ssh-host-key";
        path = "/run/ageism/ssh-host-key";
        owner = "root";
        mode = "0400";
      };
    };
  };
}
```

The service provisions a **complete generation**, not individual live files:

1. Checks that destination directories and the generation directory are safe (see below), creating missing directories.
2. Creates a private generation directory and decrypts every secret into it, finding the matching `identity.<ID>` beside the source or in an ancestor directory. Applies each secret's `owner` (via `chown`) and `mode` (via `chmod`) before publication. If caching is enabled, unchanged secrets are copied from the active generation instead.
3. Stores the manifest and cache metadata inside the generation. Configured `path` values are stable symlinks through the generation directory's `current` pointer.
4. Publishes all the secrets and metadata together by atomically replacing `current` with a symlink to the completed generation.

For example, the default layout includes:

```text
/run/ageism/
├── wifi-password -> /run/ageism/.generations/current/files/<path-hash>
└── .generations/
    ├── current -> generation-AbCdEf
    └── generation-AbCdEf/
        ├── files/<path-hash>
        ├── manifest.json
        └── state.json
```

If decryption, permission setup, or publication fails, the previous generation remains active and its cache metadata stays unchanged. Failed staging directories are removed. Existing regular files and symlinks are migrated to generation-backed paths without changing their readable contents before the switch; a failed alias setup restores the originals. Configured paths must be unique.

Atomicity is **per service**: secrets needed for user creation and regular secrets publish independently. Open file descriptors continue to refer to the generation they opened. Applications that need a consistent snapshot across multiple separate opens must pin a generation themselves; a switch can occur between opens.

Because the service runs as root, the parent directory of `path` and all of its ancestors (after resolving symlinks) must be owned by root and must not be writable by group or others. Otherwise another user could redirect the write or the `chown` to a different file. This rules out locations such as home directories and `/tmp`. Put secrets under a root-owned directory such as `/run/ageism`, which the module creates at boot (owned by root, mode `0755`), and use [systemd credentials](./systemd-credentials) or a symlink to make them available elsewhere.

An advisory lock (`flock`) in each generation directory prevents concurrent provisioning and is released automatically if the worker is killed. Do not remove the lock file while provisioning may be running. After an unclean termination, the active generation is still intact; abandoned staging directories are collected by the next successful run with pruning enabled.

Both services run with `UMask=0077` and a systemd sandbox: no network (only `AF_UNIX` sockets, so age plugins can reach daemons such as `pcscd`), no new privileges, an inaccessible `/home`, and a capability bounding set limited to `CAP_CHOWN`, `CAP_FOWNER`, `CAP_DAC_OVERRIDE` and `CAP_DAC_READ_SEARCH`. The regular service also uses a private `/tmp`; the early service does not, to avoid an ordering dependency on tmpfiles, which runs after sysusers. The rest of the file system stays writable, so `path` may be anywhere that passes the check above. Directories created for `path` get mode `0755`.

## Options

### `services.ageism.enable`

Whether to enable the `ageism-secrets` service.

### `services.ageism.secrets.<name>`

| Option | Type | Description |
|---|---|---|
| `source` | string | Path to the deployed secret, e.g. `/var/lib/ageism/sha256-<sha256>.<ID>.age`. |
| `path` | string | Absolute destination of the decrypted secret, installed as a stable symlink through the active generation. Missing parent directories are created. Every directory on the path must be owned by root and not writable by group or others. The destination must not overlap the generation directory. |
| `owner` | string | Owner of the decrypted file, as accepted by `chown` (e.g. `user` or `user:group`). |
| `mode` | string | Octal file mode of three or four digits, e.g. `"0400"`. |
| `neededForUsers` | boolean | Decrypt before `systemd-sysusers.service`, e.g. for `users.users.<name>.hashedPasswordFile`. Defaults to `false`. The secret must be owned by `root` (or UID `0`); a group suffix such as `root:root` is allowed. Other owners cause a configuration error. |

The `ageism-secrets-for-users` service is added only when at least one secret has `neededForUsers = true`. These secrets are excluded from the regular service. Each service has a separate generation directory and only prunes its own generations and aliases, so the regular service does not remove secrets needed for user creation.

### `services.ageism.settings.generationDirectory`

Directory containing plaintext generations and their `current` symlink. Defaults to `/run/ageism/.generations`. The early user-creation service uses the same path with a `.for-users` suffix. Keep this on a volatile filesystem such as `/run` so decrypted secrets are not persisted to disk. The directory and all its ancestors must be root-owned and not writable by group or others.

### `services.ageism.settings.pruneDirectory`

After successful publication, remove obsolete managed secret symlinks beneath this directory and garbage-collect older generations. The active and immediately previous generations are retained. Defaults to `null` (no pruning).

Unlike earlier versions, pruning never deletes arbitrary subdirectories or runs before decryption. Unrelated files, directories, and the other provisioning phase's aliases are left alone. Secrets omitted from the new manifest become unavailable through their configured paths at the generation switch, even without pruning; their old symlinks may remain dangling. Without pruning, old plaintext generations remain stored until manually removed or the volatile filesystem is cleared. With pruning, the immediately previous generation still contains its old plaintexts.

### `services.ageism.settings.lastManifest`

Enable caching and expose the active generation's manifest at this path via a symlink. Defaults to `null` (decrypt every secret for each generation). Unchanged entries are copied from the active generation, provided their cached files still exist. Files are copied rather than hard-linked, so generations have independent inodes. The cache and plaintexts are published by the same atomic switch: a failed update cannot leave the cache describing a different set of secrets.

The early service uses a separate manifest path with a `.for-users` suffix. A persistent manifest path does not preserve plaintexts across a reboot: if the generation directory is on `/run`, the secrets must be decrypted again.

### `services.ageism.settings.agePackage`

The age implementation used for decryption (`age` or `rage`). Defaults to `pkgs.age`.

### `services.ageism.settings.agePlugins`

A list of extra packages (e.g. age plugins) added to the service's `PATH`.

## Next steps

- Pass secrets to services without changing file ownership by using [systemd credentials](./systemd-credentials).
