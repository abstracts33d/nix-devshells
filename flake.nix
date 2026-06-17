{
  description = "Cross-platform Nix devShells for Rails projects";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-22_11.url = "github:NixOS/nixpkgs/nixos-22.11";
    nixpkgs-21_05.url = "github:NixOS/nixpkgs/nixos-21.05";
    devenv.url = "github:cachix/devenv";
    # Required by the slim rails/devenv.nix module: devenv resolves
    # `languages.ruby.version` (exact patch from .ruby-version) against this
    # input. devenv does not bundle it, so the module repo's checks declare it
    # and thread it into devenv.lib.mkShell; consumers must add it too.
    nixpkgs-ruby.url = "github:bobvanderlinden/nixpkgs-ruby";
    nixpkgs-ruby.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-stable,
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
    # interpreter is the expected version. The check FAILS hard if vips is not
    # on the library path: the loop over LD_LIBRARY_PATH finds no libvips.so.42
    # and the guard `exit 1`s.
    #
    # The slim module reads the version from the consumer's .ruby-version via
    # lib.mkDefault. Pure flake checks have no consumer project dir, so each
    # check pins `languages.ruby.version` directly with lib.mkForce — devenv
    # then resolves the exact patch from the `nixpkgs-ruby` input (threaded in
    # via `inputs`). `ruby` here is the exact patch version (e.g. "3.4.1").
    mkDevenvCheck = system: ruby: let
      pkgs = import nixpkgs {inherit system;};
      inherit (pkgs) lib;
      modules = [
        ./rails/devenv.nix
        {
          # Pin the version directly (mkForce overrides the module's
          # .ruby-version-derived mkDefault); devenv resolves the exact patch
          # from nixpkgs-ruby. The pure check has no consumer project dir, so
          # give devenv a stand-in root for its internal state/runtime paths —
          # nothing reads from it because the version is forced above.
          languages.ruby.version = lib.mkForce ruby;
          devenv.root = lib.mkForce "/build/devenv-check";
        }
      ];
      eval = devenv.lib.mkEval {
        inherit pkgs modules;
        inputs = inputs // {self = self;};
      };
      shell = devenv.lib.mkShell {
        inherit pkgs modules;
        inputs = inputs // {self = self;};
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

        # (2) ruby must be the EXACT version provisioned from nixpkgs-ruby.
        rv="$(${rubyPkg}/bin/ruby -e 'print RUBY_VERSION')"
        if [ "$rv" != "${ruby}" ]; then
          echo "FAIL: ruby is $rv, expected exactly ${ruby}" >&2
          exit 1
        fi
        echo "ok: ruby $rv"

        echo "STRUCTURAL_OK ruby=${ruby} vips=$found"
        touch $out
      '';

    # Exact patch versions, provisioned via nixpkgs-ruby from a pinned
    # `languages.ruby.version` (mkForce). All three are real flake checks; see
    # the nix flake check log for which were executed locally vs in CI (each
    # pulls + compiles a ruby, so a sandbox may run a subset — never silently).
    checkRubyVersions = ["3.2.7" "3.3.6" "3.4.1"];
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
