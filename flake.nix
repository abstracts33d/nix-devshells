{
  description = "Cross-platform Nix devShells for Rails projects";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-22_11.url = "github:NixOS/nixpkgs/nixos-22.11";
    nixpkgs-21_05.url = "github:NixOS/nixpkgs/nixos-21.05";
  };

  outputs = {
    nixpkgs,
    nixpkgs-stable,
    nixpkgs-22_11,
    nixpkgs-21_05,
    ...
  }: let
    supportedSystems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;

    mkRailsShellFor = system: {
      ruby,
      node ? true,
      extraPackages ? [],
      extraEnv ? {},
    }: let
      pkgs = import nixpkgs {inherit system;};

      # Each Ruby version uses the nixpkgs that ships it + same GCC (ABI compat)
      rubyEnv =
        {
          "3.4" = let
            p = pkgs;
          in {
            buildPkgs = p;
            rubyPkg = p.ruby_3_4;
          };
          "3.3" = let
            p = pkgs;
          in {
            buildPkgs = p;
            rubyPkg = p.ruby_3_3;
          };
          "3.2" = let
            p = import nixpkgs-stable {inherit system;};
          in {
            buildPkgs = p;
            rubyPkg = p.ruby_3_2;
          };
          "2.7" = let
            p = import nixpkgs-22_11 {inherit system;};
          in {
            buildPkgs = p;
            rubyPkg = p.ruby_2_7;
          };
          "2.6" = let
            p = import nixpkgs-21_05 {inherit system;};
          in {
            buildPkgs = p;
            rubyPkg = p.ruby_2_6;
          };
        }
        .${
          ruby
        }
        or (throw "Unsupported Ruby: ${ruby}. Supported: 3.4, 3.3, 3.2, 2.7, 2.6");

      inherit (rubyEnv) buildPkgs rubyPkg;

      nativeLibs = with buildPkgs; [
        postgresql
        (postgresql.pg_config or postgresql.dev or postgresql)
        (postgresql.lib or postgresql)
        libyaml
        libffi
        zlib
        readline
        openssl
        libxml2
        libxslt
        imagemagick
        pkg-config
        gnumake
        gcc
        # Rust toolchain for gems like commonmarker
        rustc
        cargo
      ];

      nodePackages =
        if node
        then
          (
            if builtins.elem ruby ["2.6" "2.7"]
            then [buildPkgs.nodejs buildPkgs.yarn]
            else [pkgs.nodejs_22 pkgs.yarn]
          )
        else [];

      tools = with pkgs; [
        overmind
        pgcli
        iredis
      ];
    in
      buildPkgs.mkShell {
        buildInputs = [rubyPkg] ++ nativeLibs ++ nodePackages ++ tools ++ extraPackages;

        shellHook = let
          envLines = builtins.concatStringsSep "\n" (
            buildPkgs.lib.mapAttrsToList (k: v: "export ${k}=\"${v}\"") ({
                GEM_HOME = "$PWD/.gems";
                GEM_PATH = "$PWD/.gems";
                BUNDLE_PATH = "$PWD/.gems";
                PATH = "$PWD/.gems/bin:$PWD/bin:$PATH";
                DATABASE_URL = "postgresql:///";
                REDIS_URL = "redis://localhost:6379";
                PGHOST = "/run/postgresql";
                BUNDLE_BUILD__PG = "--with-pg-config=pg_config";
                BUNDLE_BUILD__NOKOGIRI = "--use-system-libraries";
                DISABLE_SPRING = "1";
              }
              // extraEnv)
          );
        in ''
          ${envLines}
          # Strip ruby version constraint from shadow Gemfile — nixpkgs provides
          # latest patch (e.g. 3.2.8) not exact (3.2.2). Original stays clean.
          if grep -q '^ruby "' Gemfile 2>/dev/null; then
            sed '/^ruby "/d' Gemfile > .Gemfile.nix
            export BUNDLE_GEMFILE="$PWD/.Gemfile.nix"
          fi
          echo "Rails devShell: Ruby $(ruby --version | cut -d' ' -f2) | Node $(node --version 2>/dev/null || echo 'n/a')"
        '';
      };

    rubyVersions = ["3.4" "3.3" "3.2" "2.7" "2.6"];

    shellName = ruby: "rails-ruby${builtins.replaceStrings ["."] [""] ruby}";
  in {
    lib = {
      inherit mkRailsShellFor;
      mkRailsShell = {
        ruby,
        node ? true,
        extraPackages ? [],
        extraEnv ? {},
      }: {
        devShells = forAllSystems (system: {
          default = mkRailsShellFor system {inherit ruby node extraPackages extraEnv;};
        });
      };
    };

    devShells = forAllSystems (system:
      builtins.listToAttrs (map (ruby: {
          name = shellName ruby;
          value = mkRailsShellFor system {inherit ruby;};
        })
        rubyVersions)
      // {
        default = mkRailsShellFor system {ruby = "3.4";};
      });
  };
}
