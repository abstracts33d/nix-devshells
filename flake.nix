{
  description = "Cross-platform Nix devShells for Rails projects";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.11";
    # ruby_3_2 was removed from nixos-unstable (EOL during 25.11); 25.05 still
    # ships it and is new enough for devenv's buildEnv. Used only by the 3.2 check.
    nixpkgs-25_05.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-22_11.url = "github:NixOS/nixpkgs/nixos-22.11";
    nixpkgs-21_05.url = "github:NixOS/nixpkgs/nixos-21.05";
    devenv.url = "github:cachix/devenv";
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-stable,
    nixpkgs-25_05,
    nixpkgs-22_11,
    nixpkgs-21_05,
    devenv,
    ...
  } @ inputs: let
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
        vips
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

    # Tier-1 structural checks for the shared devenv module. For each ruby we
    # build the devenv shell (proves it evaluates + builds) and assert two
    # network-free invariants: (1) libvips.so.42 is reachable via the shell's
    # LD_LIBRARY_PATH — the regression that broke vconfig — and (2) the ruby
    # package is the expected major.minor. The check FAILS hard if vips is not
    # on the library path: the loop over LD_LIBRARY_PATH finds no libvips.so.42
    # and the guard `exit 1`s.
    mkDevenvCheck = system: ruby: let
      # Pick the nixpkgs that still ships a working ruby for this version: 3.4/3.3
      # are current on unstable, but ruby_3_2 was removed from unstable (EOL during
      # 25.11), so the 3.2 check uses nixos-25.05 (still ships ruby_3_2 and is new
      # enough for devenv's buildEnv). Mirrors mkRailsShellFor's per-version nixpkgs.
      checkNixpkgs =
        {
          "3.4" = nixpkgs;
          "3.3" = nixpkgs;
          "3.2" = nixpkgs-25_05;
        }
        .${
          ruby
        };
      pkgs = import checkNixpkgs {inherit system;};
      eval = devenv.lib.mkEval {
        inherit pkgs;
        inputs = inputs // {self = self;};
        modules = [
          ./rails/devenv.nix
          {digitpro.rails.ruby = ruby;}
        ];
      };
      shell = devenv.lib.mkShell {
        inherit pkgs;
        inputs = inputs // {self = self;};
        modules = [
          ./rails/devenv.nix
          {digitpro.rails.ruby = ruby;}
        ];
      };
      ldLibraryPath = eval.config.env.LD_LIBRARY_PATH;
      rubyPkg = eval.config.languages.ruby.package;
    in
      pkgs.runCommand "devenv-rails-${builtins.replaceStrings ["."] [""] ruby}-structural" {
        # Depend on the built shell so the check fails if the shell can't build.
        inherit shell;
        # Pass LD_LIBRARY_PATH as a derivation attr so its string-context store
        # paths (vips, imagemagick) are realised into the build sandbox — a bare
        # interpolation would not pull them into the input closure.
        ldLibraryPath = ldLibraryPath;
      } ''
        echo "== structural check: ruby ${ruby} =="

        # (1) libvips.so.42 must be reachable on LD_LIBRARY_PATH.
        found=""
        IFS=':'
        for dir in $ldLibraryPath; do
          if [ -e "$dir/libvips.so.42" ]; then
            found="$dir/libvips.so.42"
            break
          fi
        done
        unset IFS
        if [ -z "$found" ]; then
          echo "FAIL: libvips.so.42 not found on LD_LIBRARY_PATH ($ldLibraryPath)" >&2
          exit 1
        fi
        echo "ok: vips -> $found"

        # (2) ruby major.minor must match the configured version.
        rv="$(${rubyPkg}/bin/ruby -e 'print RUBY_VERSION' | cut -d. -f1,2)"
        if [ "$rv" != "${ruby}" ]; then
          echo "FAIL: ruby major.minor is $rv, expected ${ruby}" >&2
          exit 1
        fi
        echo "ok: ruby $rv"

        echo "STRUCTURAL_OK ruby=${ruby} vips=$found"
        touch $out
      '';

    # Wired across 3.2/3.3/3.4 (all three are real flake checks). Locally only
    # 3.4 was executed to prove the mechanism (3.2/3.3 pull a second nixpkgs and
    # compile ruby from source — too slow for the sandbox); CI runs all three.
    checkRubyVersions = ["3.2" "3.3" "3.4"];
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

    templates.rails = {
      path = ./templates/rails;
      description = "Rails project with devenv (Ruby, PostgreSQL, Redis)";
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

    checks = forAllSystems (system:
      builtins.listToAttrs (map (ruby: {
          name = "devenv-rails-${builtins.replaceStrings ["."] [""] ruby}";
          value = mkDevenvCheck system ruby;
        })
        checkRubyVersions));
  };
}
