# NixOS module

The flake exports a NixOS module as `nixosModules.default`. It adds a oneshot systemd service, `ageism-decrypt`, that decrypts deployed secrets into their final locations at boot (and on reload whenever the secret list changes).

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

For each secret, the service:

1. Checks that the parent directory of `path` is safe (see below), creating it if missing.
2. Skips the secret if `path` is already a regular file, and fails if it is anything else, such as a symlink.
3. Derives the identity ID from the `source` filename and decrypts it with `identity.<ID>` in the same directory.
4. Decrypts the plaintext into a private temporary directory next to `path`, applies `owner` (via `chown`) and `mode` (via `chmod`), and renames the file to `path`.

The service fails if any secret could not be installed, after attempting all of them.

Because the service runs as root, the parent directory of `path` and all of its ancestors (after resolving symlinks) must be owned by root and must not be writable by group or others. Otherwise another user could redirect the write or the `chown` to a different file. This rules out locations such as home directories and `/tmp`. Put secrets under a root-owned directory such as `/run/ageism`, and use [systemd credentials](./systemd-credentials) or a symlink to make them available elsewhere.

## Options

### `services.ageism.enable`

Whether to enable the `ageism-decrypt` service.

### `services.ageism.secrets.<name>`

| Option | Type | Description |
|---|---|---|
| `source` | string | Path to the deployed secret, e.g. `/var/lib/ageism/sha256-<sha256>.<ID>.age`. |
| `path` | string | Destination of the decrypted secret. Missing parent directories are created. Every directory on the path must be owned by root and not writable by group or others. |
| `owner` | string | Owner of the decrypted file, as accepted by `chown` (e.g. `user` or `user:group`). |
| `mode` | string | Octal file mode, e.g. `"0400"`. |

### `services.ageism.settings.agePackage`

The age implementation used for decryption (`age` or `rage`). Defaults to `pkgs.age`.

### `services.ageism.settings.agePlugins`

A list of extra packages (e.g. age plugins) added to the service's `PATH`.

## Next steps

- Pass secrets to services without changing file ownership by using [systemd credentials](./systemd-credentials).
