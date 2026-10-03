# systemd credentials

systemd can pass secrets to a service as [credentials](https://systemd.io/CREDENTIALS/). Load a secret decrypted by the [NixOS module](./nixos-module) with `LoadCredential=`. The service then reads it from its own credentials directory, so it does not need read access to the decrypted file.

This works well when:

- The service runs as a dynamic or unprivileged user (`DynamicUser=yes`). The decrypted file can stay owned by `root`.
- Several services need the same secret, each under its own user.
- The program accepts a path to a secret file, such as a `--password-file` option or a `*File` setting.

## Example

Decrypt the secret into `/run`, owned by root and readable only by root:

```nix
{ config, pkgs, ... }:
let
  index = builtins.fromJSON (builtins.readFile ./indices/host1.json);
  secrets = config.services.ageism.secrets;
in
{
  services.ageism = {
    enable = true;
    secrets.my-app-token = {
      source = "/var/lib/ageism/${index.my-app-token}";
      path = "/run/ageism/my-app-token";
      owner = "root";
      mode = "0400";
    };
  };

  systemd.services.my-app = {
    wantedBy = [ "multi-user.target" ];
    wants = [ "ageism-decrypt.service" ];
    after = [ "ageism-decrypt.service" ];

    serviceConfig = {
      DynamicUser = true;
      LoadCredential = [ "token:${secrets.my-app-token.path}" ];
      ExecStart = "${pkgs.my-app}/bin/my-app --token-file=%d/token";
    };
  };
}
```

- `LoadCredential=token:PATH` copies the file at `PATH` into the service's credentials directory as `token`. systemd reads the file as root, so `owner = "root"` and `mode = "0400"` are enough.
- `%d` expands to the credentials directory in unit settings. At runtime the program can also find it in the `$CREDENTIALS_DIRECTORY` environment variable, e.g. `$CREDENTIALS_DIRECTORY/token`.
- Reference the path as `config.services.ageism.secrets.<name>.path` so it is defined in one place.

## Ordering

`ageism-decrypt.service` is a oneshot service. Order consumers after it with `after`, and pull it in with `wants`, so the decrypted file exists when systemd loads the credential. Without the ordering, the service can start before the file exists, and `LoadCredential=` fails.

## Updating a secret

`ageism-decrypt` skips a secret whose `path` already exists. If a secret changes but keeps the same `path`, the old plaintext stays in place until the file is removed. Keeping `path` under `/run` (a tmpfs) means it is cleared on reboot. Restart consuming services after updating so they load the new credential.

## Encrypted credentials

systemd also supports `LoadCredentialEncrypted=` with files produced by `systemd-creds encrypt`. ageism does not produce that format. Use `LoadCredential=` with the plaintext decrypted by the NixOS module, as shown above.
