{
  description = "Always up-to-date Nix package for Grok Build (grok), xAI's terminal coding agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      version = (lib.importJSON ./sources.json).version;

      overlay = final: _prev: {
        grok = final.callPackage ./package.nix { };
      };
    in
    {
      overlays.default = overlay;

      packages = forAllSystems (
        system:
        let
          grok = (pkgsFor system).callPackage ./package.nix { };
        in
        {
          inherit grok;
          default = grok;
        }
      );

      apps = forAllSystems (system: rec {
        grok = {
          type = "app";
          program = lib.getExe self.packages.${system}.grok;
        };
        default = grok;
      });

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          inherit (self.packages.${system}) grok;

          # Guards the wrapper, not just the fetch: runs the real binary and
          # confirms the auto-updater kill switch is baked into the wrapper.
          grok-smoke =
            pkgs.runCommand "grok-smoke"
              {
                grok = self.packages.${system}.grok;
                nativeBuildInputs = [ self.packages.${system}.grok ];
              }
              ''
                grok --version | tee version.txt
                grep -qF "${version}" version.txt

                grok --help > help.txt
                grep -qF "Grok Build" help.txt

                grep -qa GROK_DISABLE_AUTOUPDATER "$grok/bin/grok" || {
                  echo "wrapper does not set GROK_DISABLE_AUTOUPDATER" >&2
                  exit 1
                }

                mv version.txt $out
              '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              actionlint
              curl
              gh
              jq
              nixfmt
              shellcheck
            ];
          };
        }
      );

      # nixfmt-tree, not bare nixfmt: `nix fmt` passes paths, which plain nixfmt
      # cannot walk.
      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);
    };
}
