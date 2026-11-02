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

The service provisions a **complete generation per directory**, not individual live files:

1. Checks that destination directories are safe (see below), creating missing directories.
2. Inside each destination directory, stages a private generation in the hidden `.ageism` store and decrypts every secret destined for that directory into it, finding the matching `identity.<ID>` beside the source or in an ancestor directory. Applies each secret's `owner` (via `chown`) and `mode` (via `chmod`) before publication. If caching is enabled, unchanged secrets are copied from that directory's active generation instead. Cache metadata (`state.json`) is stored inside the generation.
3. Installs each configured `path` as a *relative* symlink `.ageism/current/<name>` (`.ageism.for-users/current/<name>` for secrets needed for user creation).
4. Publishes the directory by atomically replacing the store's `current` symlink with one to the completed generation. No directory is published until decryption and permission setup have succeeded for **every** directory; a failure rolls back the directories already published in the same run.

For example, the default layout includes:

```text
/run/ageism/
├── wifi-password -> .ageism/current/wifi-password
├── ssh-host-key -> .ageism/current/ssh-host-key
└── .ageism/
    ├── lock
    ├── current -> generation-AbCdEf
    └── generation-AbCdEf/
        ├── wifi-password
        ├── ssh-host-key
        └── state.json
```

Every symlink is relative and resolves inside the destination directory that contains it, so bind-mounting a destination directory (or any of its ancestors) elsewhere never leaves dead links. Open file descriptors continue to refer to the generation they were opened from.

Switching is atomic **per directory**: all secrets in one directory change together, but directories switch one after another, so a reader that opens secrets in different directories during an update can briefly see a mix of old and new values. Applications that need a consistent snapshot across directories must order their restarts or pin a generation themselves; a switch can also occur between separate opens in the same directory.

If decryption, permission setup, or publication fails, the previous generations remain active and their cache metadata stays unchanged. Installed symlinks are removed or restored to the original files, and failed staging directories are deleted. Existing regular files and symlinks are migrated to generation-backed paths without changing their readable contents before the switch; a failed alias setup restores the originals. Configured paths must be unique, must not contain a `.ageism` component, and must not be named `state.json`.

Because the service runs as root, the parent directory of `path` and all of its ancestors (after resolving symlinks) must be owned by root and must not be writable by group or others. Otherwise another user could redirect the write or the `chown` to a different file. This rules out locations such as home directories and `/tmp`. Put secrets under a root-owned directory such as `/run/ageism`, which the module creates at boot (owned by root, mode `0755`), and use [systemd credentials](./systemd-credentials) to make them available elsewhere.

An advisory lock (`flock`) in each generation store prevents concurrent provisioning of the same directory and is released automatically if the worker is killed. Do not remove the lock file while provisioning may be running. After an unclean termination, the active generations are still intact; abandoned staging directories are collected by the next successful run with pruning enabled.

Secrets needed for user creation use a store named `.ageism.for-users`, so the user-creation phase and the regular phase publish and prune independently even when their secrets live in the same directory.

Both services run with `UMask=0077` and a systemd sandbox: no network (only `AF_UNIX` sockets, so age plugins can reach daemons such as `pcscd`), no new privileges, an inaccessible `/home`, and a capability bounding set limited to `CAP_CHOWN`, `CAP_FOWNER`, `CAP_DAC_OVERRIDE` and `CAP_DAC_READ_SEARCH`. The regular service also uses a private `/tmp`; the early service does not, to avoid an ordering dependency on tmpfiles, which runs after sysusers. The rest of the file system stays writable, so `path` may be anywhere that passes the check above. Directories created for `path` get mode `0755`.

## Options

### `services.ageism.enable`

Whether to enable the `ageism-secrets` service.

### `services.ageism.secrets.<name>`

| Option | Type | Description |
|---|---|---|
| `source` | string | Path to the deployed secret, e.g. `/var/lib/ageism/sha256-<sha256>.<ID>.age`. |
| `path` | string | Absolute destination of the decrypted secret, installed as a relative symlink into the `.ageism` generation store in its parent directory. Missing parent directories are created. Every directory on the path must be owned by root and not writable by group or others. The path must not contain a `.ageism` component, and its basename must not be `state.json`. |
| `owner` | string | Owner of the decrypted file, as accepted by `chown` (e.g. `user` or `user:group`). |
| `mode` | string | Octal file mode of three or four digits, e.g. `"0400"`. |
| `neededForUsers` | boolean | Decrypt before `systemd-sysusers.service`, e.g. for `users.users.<name>.hashedPasswordFile`. Defaults to `false`. The secret must be owned by `root` (or UID `0`); a group suffix such as `root:root` is allowed. Other owners cause a configuration error. |

The `ageism-secrets-for-users` service is added only when at least one secret has `neededForUsers = true`. These secrets are excluded from the regular service. Each phase has its own generation store in every destination directory (`.ageism` and `.ageism.for-users`) and only prunes its own generations and symlinks, so the regular service does not remove secrets needed for user creation.

Each destination directory contains its own generation store, created automatically; there is no shared generation directory. Keep destination directories on a volatile filesystem such as `/run` so decrypted plaintexts are not persisted to disk.

### `services.ageism.settings.pruneDirectory`

After successful publication, remove obsolete managed secret symlinks beneath this directory and garbage-collect older generations. The active and immediately previous generations are retained. Defaults to `null` (no pruning).

Unlike earlier versions, pruning never deletes arbitrary subdirectories or runs before decryption. Unrelated files, directories, and the other provisioning phase's symlinks are left alone. A secret omitted from the new manifest becomes unavailable as soon as its directory switches to the new generation; a directory without remaining secrets keeps serving its last generation until pruning (or a reboot, on a tmpfs) retires it. Without pruning, old plaintext generations remain stored until manually removed or the volatile filesystem is cleared. With pruning, the immediately previous generation still contains its old plaintexts.

### `services.ageism.settings.lastManifest`

Write the manifest of the last fully successful run to this file, and enable caching. Defaults to `null` (decrypt every secret for each generation). Unchanged entries are copied from the active generation of their directory, provided their cached files still exist. Files are copied rather than hard-linked, so generations have independent inodes. The file is a plain record for the operator; reuse decisions read the cache state committed inside each generation, so a failed update cannot leave the cache describing a different set of secrets.

The early service uses a separate manifest path with a `.for-users` suffix. A persistent manifest path does not preserve plaintexts across a reboot: if the destination directories are on `/run`, the secrets must be decrypted again.

### `services.ageism.settings.agePackage`

The age implementation used for decryption (`age` or `rage`). Defaults to `pkgs.age`.

### `services.ageism.settings.agePlugins`

A list of extra packages (e.g. age plugins) added to the service's `PATH`.

## Next steps

- Pass secrets to services without changing file ownership by using [systemd credentials](./systemd-credentials).
