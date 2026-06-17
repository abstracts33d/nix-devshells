{
  description = "Smoke-test harness for the shared Rails devenv module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    devenv.url = "github:cachix/devenv";
  };

  outputs = { self, nixpkgs, devenv, ... } @ inputs:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {
      devShells = forAllSystems (system: {
        default = devenv.lib.mkShell {
          inherit inputs;
          pkgs = import nixpkgs { inherit system; };
          modules = [
            ../../rails/devenv.nix
            { digitpro.rails.ruby = "3.4"; }
          ];
        };
      });
    };
}
