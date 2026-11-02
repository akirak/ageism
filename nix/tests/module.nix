{ pkgs }:
let
  inherit (pkgs) lib;

  evaluate =
    ageism:
    (import "${pkgs.path}/nixos/lib/eval-config.nix" {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ../module.nix
        {
          system.stateVersion = "25.05";
          systemd.sysusers.enable = true;
          services.ageism = ageism;
        }
      ];
    }).config;

  secret = {
    source = "/var/lib/ageism/sha256-example.identity.age";
    path = "/run/ageism/password";
    owner = "root";
    mode = "0400";
  };
  settings = {
    pruneDirectory = "/run/ageism";
    lastManifest = "/var/lib/ageism/last-manifest.json";
  };

  disabled = evaluate {
    enable = false;
    secrets.password = secret // {
      neededForUsers = true;
    };
  };
  empty = evaluate {
    enable = true;
    secrets = { };
  };
  regular = evaluate {
    enable = true;
    inherit settings;
    secrets.regular = secret;
  };
  mixed = evaluate {
    enable = true;
    inherit settings;
    secrets = {
      regular = secret // {
        path = "/run/ageism/regular";
      };
      password = secret // {
        neededForUsers = true;
      };
    };
  };
  earlyOnly = evaluate {
    enable = true;
    secrets.password = secret // {
      neededForUsers = true;
    };
  };

  regularService = regular.systemd.services.ageism-secrets;
  mixedRegularService = mixed.systemd.services.ageism-secrets;
  earlyService = mixed.systemd.services.ageism-secrets-for-users;
  manifest = service: toString (lib.head service.reloadTriggers);
  expectedManifest = secrets: toString (pkgs.writers.writeJSON "secret-index.json" secrets);

  ownershipAssertions =
    neededForUsers: owner:
    lib.filter (a: !a.assertion && lib.hasPrefix "services.ageism.secrets." a.message)
      (evaluate {
        enable = true;
        secrets.password = secret // {
          inherit neededForUsers owner;
        };
      }).assertions;

  failures = lib.runTests {
    testUserSecretsRootOwnership = {
      expr = map (owner: lib.all (a: a.assertion) (ownershipAssertions true owner)) [
        "root"
        "root:root"
        "0"
        "0:0"
        "alice"
        "alice:root"
        "1000"
        "1000:0"
      ];
      expected = [
        true
        true
        true
        true
        false
        false
        false
        false
      ];
    };
    testOwnershipErrorNamesSecret = {
      expr = map (a: lib.hasInfix "secrets.password" a.message && lib.hasInfix "root" a.message) (
        lib.filter (a: !a.assertion) (ownershipAssertions true "alice")
      );
      expected = [ true ];
    };
    testRegularSecretCanHaveNonRootOwner = {
      expr = lib.all (a: a.assertion) (ownershipAssertions false "alice");
      expected = true;
    };
    testDisabledSkipsOwnershipAssertion = {
      expr =
        lib.filter (a: !a.assertion && lib.hasPrefix "services.ageism.secrets." a.message)
          (evaluate {
            enable = false;
            secrets.password = secret // {
              neededForUsers = true;
              owner = "alice";
            };
          }).assertions;
      expected = [ ];
    };
    testDisabled = {
      expr = lib.filterAttrs (name: _: lib.hasPrefix "ageism-secrets" name) disabled.systemd.services;
      expected = { };
    };
    testEmpty = {
      expr = empty.systemd.services ? ageism-secrets-for-users;
      expected = false;
    };
    testDefault = {
      expr = regular.services.ageism.secrets.regular.neededForUsers;
      expected = false;
    };
    testRegularOnly = {
      expr = regular.systemd.services ? ageism-secrets-for-users;
      expected = false;
    };
    testRegularManifest = {
      expr = manifest regularService;
      expected = expectedManifest { regular = secret; };
    };
    testSplitManifests = {
      expr = [
        (manifest mixedRegularService)
        (manifest earlyService)
      ];
      expected = [
        (expectedManifest {
          regular = secret // {
            path = "/run/ageism/regular";
          };
        })
        (expectedManifest { password = secret; })
      ];
    };
    testEarlyOnlyManifest = {
      expr = manifest earlyOnly.systemd.services.ageism-secrets;
      expected = expectedManifest { };
    };
    testEarlyOrdering = {
      expr = {
        inherit (earlyService) wantedBy before after;
        inherit (earlyService.unitConfig) DefaultDependencies;
        inherit (earlyService.serviceConfig) Type PrivateTmp;
      };
      expected = {
        wantedBy = [ "systemd-sysusers.service" ];
        before = [ "systemd-sysusers.service" ];
        after = [ "local-fs.target" ];
        DefaultDependencies = false;
        Type = "oneshot";
        PrivateTmp = false;
      };
    };
    testRegularOrdering = {
      expr = {
        inherit (mixedRegularService) wantedBy after;
        inherit (mixedRegularService.serviceConfig) PrivateTmp;
      };
      expected = {
        wantedBy = [ "multi-user.target" ];
        after = [ "ageism-secrets-for-users.service" ];
        PrivateTmp = true;
      };
    };
    testPruning = {
      expr = map (service: lib.hasInfix "--prune /run/ageism" service.script) [
        regularService
        mixedRegularService
        earlyService
      ];
      expected = [
        true
        true
        true
      ];
    };
    testPhaseStores = {
      expr = [
        (lib.hasInfix "--for-users " earlyService.script)
        (lib.hasInfix "--for-users" mixedRegularService.script)
      ];
      expected = [
        true
        false
      ];
    };
    testDuplicatePaths = {
      expr =
        lib.any (a: !a.assertion && lib.hasInfix "paths must be unique" a.message)
          (evaluate {
            enable = true;
            secrets = {
              regular = secret;
              password = secret // {
                neededForUsers = true;
              };
            };
          }).assertions;
      expected = true;
    };
    testSeparateLastManifests = {
      expr = [
        (lib.hasInfix "--last-manifest ${settings.lastManifest}" mixedRegularService.script)
        (lib.hasInfix "--last-manifest ${settings.lastManifest}.for-users" earlyService.script)
        (lib.hasInfix "install -d -m 0755 -- /var/lib/ageism" earlyService.preStart)
      ];
      expected = [
        true
        true
        true
      ];
    };
    testNoOptionalSettings = {
      expr =
        lib.any (flag: lib.hasInfix flag earlyOnly.systemd.services.ageism-secrets-for-users.script)
          [
            "--prune"
            "--last-manifest"
          ];
      expected = false;
    };
  };
in
assert lib.assertMsg (failures == [ ]) (builtins.toJSON failures);
pkgs.runCommand "ageism-module-tests" { } ''
  touch "$out"
''
