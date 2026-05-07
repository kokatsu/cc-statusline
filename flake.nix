{
  description = "Fast Claude Code statusline written in Zig";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    supportedSystems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin"];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    pkgsFor = system: nixpkgs.legacyPackages.${system};
  in {
    packages = forAllSystems (system: let
      pkgs = pkgsFor system;
      cc-statusline = pkgs.stdenvNoCC.mkDerivation {
        pname = "cc-statusline";
        version = "0.1.0";
        src = ./.;
        nativeBuildInputs = [pkgs.zig];
        dontConfigure = true;
        dontFixup = true;
        buildPhase = ''
          export HOME=$TMPDIR
          export XDG_CACHE_HOME=$TMPDIR/.cache
          zig build -Doptimize=ReleaseFast --prefix $out
        '';
      };
    in {
      inherit cc-statusline;
      default = cc-statusline;
    });

    overlays.default = _final: prev: {
      cc-statusline = self.packages.${prev.system}.cc-statusline;
    };

    devShells = forAllSystems (system: {
      default = (pkgsFor system).mkShell {
        packages = [(pkgsFor system).zig];
      };
    });

    formatter = forAllSystems (system: (pkgsFor system).alejandra);
  };
}
