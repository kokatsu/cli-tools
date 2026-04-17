{
  description = "Custom CLI tools written in Zig";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    supportedSystems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin"];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    pkgsFor = system: nixpkgs.legacyPackages.${system};

    mkZigTool = pkgs: {
      pname,
      subdir,
      optimize ? "ReleaseFast",
    }:
      pkgs.stdenvNoCC.mkDerivation {
        inherit pname;
        version = "0.1.0";
        src = ./.;
        nativeBuildInputs = [pkgs.zig];
        dontConfigure = true;
        dontFixup = true;
        buildPhase = ''
          export HOME=$TMPDIR
          export XDG_CACHE_HOME=$TMPDIR/.cache
          cd ${subdir}
          zig build -Doptimize=${optimize} --prefix $out
        '';
      };
  in {
    packages = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      cc-filter = mkZigTool pkgs {
        pname = "cc-filter";
        subdir = "cc-filter";
        optimize = "ReleaseSafe";
      };
      cc-statusline = mkZigTool pkgs {
        pname = "cc-statusline";
        subdir = "cc-statusline";
      };
      daily = mkZigTool pkgs {
        pname = "daily";
        subdir = "daily";
      };
      memo = mkZigTool pkgs {
        pname = "memo";
        subdir = "memo";
      };
    });

    overlays.default = _final: prev: {
      inherit
        (self.packages.${prev.system})
        cc-filter
        cc-statusline
        daily
        memo
        ;
    };

    devShells = forAllSystems (system: {
      default = (pkgsFor system).mkShell {
        packages = [(pkgsFor system).zig];
      };
    });

    formatter = forAllSystems (system: (pkgsFor system).alejandra);
  };
}
