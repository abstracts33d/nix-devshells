{
  description = "Smoke-test harness for the shared Rails devenv module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    devenv.url = "github:cachix/devenv";
    # The slim module resolves languages.ruby.version (read from .ruby-version)
    # against this input; consumers must declare it too.
    nixpkgs-ruby.url = "github:bobvanderlinden/nixpkgs-ruby";
    nixpkgs-ruby.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, devenv, ... } @ inputs:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {
      devShells = forAllSystems (system: {
        # The module reads the Ruby version from this fixture's .ruby-version
        # (3.4.1) via config.devenv.root, which requires `--impure`.
        default = devenv.lib.mkShell {
          inherit inputs;
          pkgs = import nixpkgs { inherit system; };
          modules = [
            ../../rails/devenv.nix
          ];
        };
      });
    };
}
