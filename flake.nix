{
  inputs = {
    nixpkgs.url = "github:nix-ocaml/nix-overlays";
  };

  outputs =
    {
      nixpkgs,
      self,
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
    in
    {
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
            ];

            checkInputs = with ocamlPackages; [
              alcotest
            ];
          };
        }
      );

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
    };
}
