{
  inputs = {
    nixpkgs.url = "github:nix-ocaml/nix-overlays";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      self,
      treefmt-nix,
      ...
    }:
    let
      eachSystem =
        f:
        nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed (
          system:
          f system (
            nixpkgs.legacyPackages.${system}.extend (
              _self: super: {
                # You can set the OCaml version to a particular release. Also, you
                # may have to pin some packages to a particular revision if the
                # devshell fail to build. This should be resolved in the upstream.
                ocamlPackages = super.ocaml-ng.ocamlPackages_latest;
              }
            )
          )
        );

      treefmtEval = eachSystem (
        _system: pkgs:
        treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";

          programs.biome.enable = true;
          programs.nixfmt.enable = true;
          programs.ocamlformat.enable = true;
          programs.zizmor.enable = true;
        }
      );
    in
    {
      nixosModules.default = import ./nix/module.nix;

      packages = eachSystem (
        _system: pkgs: with pkgs; {
          default = ocamlPackages.buildDunePackage {
            pname = "ageism";
            version = "0.1";
            duneVersion = "3";
            src = self.outPath;

            buildInputs = with ocamlPackages; [ ocaml-syntax-shims ];

            propagatedBuildInputs = with ocamlPackages; [
              eio
              eio_main
              yojson
              ppx_yojson_conv
              cmdliner
              digestif
              fmt
            ];

            checkInputs = with ocamlPackages; [
              alcotest
            ];

            meta.mainProgram = "ageism";
          };
        }
      );

      formatter = eachSystem (system: _pkgs: treefmtEval.${system}.config.build.wrapper);
      devShells = eachSystem (
        system: pkgs: {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.default ];
            packages = with pkgs.ocamlPackages; [
              ocaml-lsp
              ocamlformat
              ocp-indent
              utop
              alcotest
            ];
          };
        }
      );

      checks = eachSystem (
        system: _pkgs:
        {
          treefmt = treefmtEval.${system}.config.build.check self;
        }
        // self.packages.${system}
      );
    };
}
