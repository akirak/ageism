# Generating a host key

Each host needs its own age identity. Keep the plaintext identity only long enough to encrypt it to your master recipient; commit the encrypted identity and its public recipient to the repository.

The examples below use `host1` as the host name. Replace `age1MASTER...` with the recipient for the master identity that you pass to ageism with `--identity`.

## Generate a software identity

Create the host directories and generate an identity with `age`:

```bash
mkdir -p secrets/host1 recipients
age-keygen -o host1-identity.txt
```

You can use the compatible `rage` tools instead:

```bash
rage-keygen -o host1-identity.txt
```

`host1-identity.txt` contains the host's private key. Do not commit this plaintext file.

## Encrypt and commit the identity

Encrypt the identity to your master recipient:

```bash
age --encrypt \
  --recipient age1MASTER... \
  --output secrets/host1/identity.age \
  host1-identity.txt
```

If you generated the identity with `rage`, you can replace `age` with `rage` in this command.

Extract the public recipient from the identity and put it in the recipients directory. The recipient normally starts with `age`:

```bash
age-keygen -y host1-identity.txt > recipients/host1.txt
```

With `rage`, use `rage-keygen -y` instead. The file names must match the host name: ageism pairs `secrets/host1/identity.age` with `recipients/host1.txt`.

Remove the plaintext identity, then commit the encrypted identity and public recipient:

```bash
rm host1-identity.txt
git add secrets/host1/identity.age recipients/host1.txt
git commit -m "Add host1 age identity"
```

## Generate a YubiKey identity

To keep the host key on a YubiKey, generate its identity file with `age-plugin-yubikey`:

```bash
age-plugin-yubikey --generate > host1-identity.txt
```

The command configures a YubiKey slot and writes an identity file containing the information needed to use that key. Copy the recipient shown in the identity file (normally starting with `age`) to `recipients/host1.txt`, one recipient per line. Then encrypt `host1-identity.txt` to the master recipient as `secrets/host1/identity.age`, remove the plaintext file, and commit the encrypted identity and recipient as described above.

The target needs the plugin when the NixOS module decrypts secrets. Add it to the service's plugin packages:

```nix
{ pkgs, ... }:
{
  services.ageism.settings.agePlugins = [
    pkgs.age-plugin-yubikey
  ];
}
```

The YubiKey must be connected and available through PC/SC when `ageism-secrets` runs.

## Next steps

- [Deploy the secrets](./getting-started#deploy-to-remote-hosts).
- Configure decryption with the [NixOS module](./nixos-module).
