{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.ageism;

  hasUserSecrets = lib.any (secret: secret.neededForUsers) (lib.attrValues cfg.secrets);

  # neededForUsers controls scheduling, not the decryption manifest format.
  mkIndex =
    predicate:
    pkgs.writers.writeJSON "secret-index.json" (
      lib.mapAttrs (_: secret: removeAttrs secret [ "neededForUsers" ]) (
        lib.filterAttrs (_: secret: predicate secret) cfg.secrets
      )
    );

  indexPathForRegularSecrets = mkIndex (secret: !secret.neededForUsers);
  indexPathForUserSecrets = mkIndex (secret: secret.neededForUsers);

  mkSecretsService =
    {
      indexPath,
      forUsers ? false,
    }:
    let
      # Each phase has its own store in every destination directory, so they
      # publish and prune independently even in shared directories.
      lastManifest =
        if cfg.settings.lastManifest == null then
          null
        else
          cfg.settings.lastManifest + lib.optionalString forUsers ".for-users";
    in
    {
      # userborn.service is aliased as systemd-sysusers.service, so userborn doesn't need an extra care.
      wantedBy = [ (if forUsers then "systemd-sysusers.service" else "multi-user.target") ];
      before = lib.optional forUsers "systemd-sysusers.service";
      after =
        if forUsers then
          [ "local-fs.target" ]
        else
          lib.optional hasUserSecrets "ageism-secrets-for-users.service";
      unitConfig.DefaultDependencies = !forUsers;
      description = if forUsers then "Decrypt age secrets for user creation" else "Decrypt age secrets";
      reloadTriggers = [ indexPath ];

      path = [
        cfg.settings.agePackage
        pkgs.coreutils
        pkgs.util-linux
      ]
      ++ cfg.settings.agePlugins;

      environment.AGE_BIN = lib.getExe cfg.settings.agePackage;

      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";

        CapabilityBoundingSet = [
          "CAP_CHOWN"
          "CAP_FOWNER"
          "CAP_DAC_OVERRIDE"
          "CAP_DAC_READ_SEARCH"
        ];
        NoNewPrivileges = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        SystemCallArchitectures = "native";

        # PrivateTmp adds an implicit dependency on tmpfiles, which runs after sysusers.
        PrivateTmp = !forUsers;
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";

        # Age plugins may talk to local daemons such as pcscd over AF_UNIX.
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
      };

      # The early service cannot wait for tmpfiles to create the state directory.
      preStart = lib.optionalString (forUsers && lastManifest != null) ''
        install -d -m 0755 -- ${lib.escapeShellArg (dirOf lastManifest)}
      '';

      script = ''
        ${lib.getExe pkgs.nodejs} ${./decrypt-secrets.mjs} ${indexPath}${lib.optionalString forUsers " --for-users"}${
          lib.optionalString (
            cfg.settings.pruneDirectory != null
          ) " --prune ${lib.escapeShellArg cfg.settings.pruneDirectory}"
        }${lib.optionalString (lastManifest != null) " --last-manifest ${lib.escapeShellArg lastManifest}"}
      '';
    };
in

{
  options = {
    services.ageism = with lib; {
      enable = mkEnableOption "Ageism";

      secrets = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              path = mkOption {
                type = types.str;
                description = "Absolute destination of the decrypted secret, installed as a relative symlink into the .ageism generation store inside its parent directory.";
              };
              source = mkOption {
                type = types.str;
              };
              owner = mkOption {
                type = types.str;
              };
              mode = mkOption {
                type = types.strMatching "[0-7]{3,4}";
              };
              neededForUsers = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Decrypt this secret before systemd-sysusers creates users, for
                  example for users.users.<name>.hashedPasswordFile. The secret
                  must be owned by root.
                '';
              };
            };
          }
        );
      };

      settings = {
        pruneDirectory = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "/run/ageism";
          description = ''
            After successfully publishing a generation, remove obsolete managed
            secret symlinks beneath this directory, switch stores whose
            directories no longer have secrets of the phase to an empty
            generation, and garbage-collect older generations in the managed
            stores. The active and immediately previous generations are
            retained. Unrelated files and directories are never removed.
          '';
        };

        lastManifest = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "/var/lib/ageism/last-manifest.json";
          description = ''
            Write the manifest of the last successful run to this file and
            enable caching: unchanged entries are copied from the active
            generation of their directory, provided their cached files still
            exist. Files are copied rather than hard-linked, so generations
            have independent inodes. The file is a plain record; reuse
            decisions read the cache state committed inside each generation,
            so a failed update cannot leave the cache describing a different
            set of secrets. After reboot, secrets on /run are decrypted again.
            Secrets needed for user creation use a separate path with a
            .for-users suffix.
          '';
        };

        agePackage = mkOption {
          type = types.package;
          default = pkgs.age;
          defaultText = literalExpression "pkgs.age";
          description = "Age package (usually age or rage)";
        };

        agePlugins = mkOption {
          type = types.listOf types.package;
          default = [ ];
          description = "Extra packages loaded into the decryption script";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      lib.mapAttrsToList (name: secret: {
        assertion =
          !secret.neededForUsers
          || lib.elem (lib.head (lib.splitString ":" secret.owner)) [
            "root"
            "0"
          ];
        message = "services.ageism.secrets.${name}: secrets with neededForUsers = true must be owned by root (owner must be root or UID 0, optionally followed by a group).";
      }) cfg.secrets
      ++ [
        {
          assertion =
            let
              paths = map (secret: secret.path) (lib.attrValues cfg.secrets);
            in
            builtins.length paths == builtins.length (lib.unique paths);
          message = "services.ageism: secret paths must be unique across both provisioning phases.";
        }
      ];

    systemd.tmpfiles.rules = [
      "d /run/ageism 0755 root root -"
    ]
    ++ lib.optional (
      cfg.settings.lastManifest != null
    ) "d ${dirOf cfg.settings.lastManifest} 0755 root root -";

    systemd.services.ageism-secrets = mkSecretsService {
      indexPath = indexPathForRegularSecrets;
    };

    systemd.services.ageism-secrets-for-users = lib.mkIf hasUserSecrets (mkSecretsService {
      indexPath = indexPathForUserSecrets;
      forUsers = true;
    });
  };
}
