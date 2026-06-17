{ lib, pkgs, config, ... }:
let
  cfg = config.digitpro.rails;
  rubyPkg = { "2.7" = pkgs.ruby_2_7; "3.2" = pkgs.ruby_3_2; "3.3" = pkgs.ruby_3_3; "3.4" = pkgs.ruby_3_4; }.${cfg.ruby};
  nodePkg = { "22" = pkgs.nodejs_22; "24" = pkgs.nodejs_24; }.${cfg.node.version};
  vips =
    if pkgs.stdenv.isDarwin
    then (pkgs.vips.override { matio = null; withIntrospection = false; }).overrideAttrs
           (prev: { mesonFlags = (prev.mesonFlags or []) ++ [ "-Dmatio=disabled" ]; })
    else pkgs.vips;
in {
  options.digitpro.rails = {
    ruby = lib.mkOption {
      type = lib.types.enum [ "2.7" "3.2" "3.3" "3.4" ];
      description = "Ruby version; maps to an ABI-correct nixpkgs.";
    };
    node = {
      enable = lib.mkOption { type = lib.types.bool; default = true; };
      version = lib.mkOption { type = lib.types.enum [ "22" "24" ]; default = "22"; };
      packageManager = lib.mkOption { type = lib.types.enum [ "yarn" "npm" ]; default = "yarn"; };
    };
    postgres = {
      enable = lib.mkOption { type = lib.types.bool; default = false; };
      package = lib.mkOption { type = lib.types.package; default = pkgs.postgresql; };
    };
    redis.enable = lib.mkOption { type = lib.types.bool; default = false; };
    devenvUp.enable = lib.mkOption { type = lib.types.bool; default = false; };
    extraPackages = lib.mkOption { type = lib.types.listOf lib.types.package; default = []; };
    extraEnv = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = {}; };
  };

  config = {
    languages.ruby = {
      enable = true;
      package = rubyPkg;
      bundler.enable = false;  # use Ruby's bundled bundler (avoids rubygems integrity conflict)
    };

    languages.javascript = lib.mkIf cfg.node.enable {
      enable = true;
      package = nodePkg;
      yarn.enable = cfg.node.packageManager == "yarn";
      npm.enable = cfg.node.packageManager == "npm";
    };

    packages = with pkgs; [
      libyaml libffi zlib readline openssl libxml2 libxslt
      imagemagick vips pkg-config gnumake gcc
    ] ++ lib.optionals cfg.postgres.enable [ cfg.postgres.package cfg.postgres.package.pg_config ]
      ++ cfg.extraPackages;

    env = {
      BUNDLE_BUILD__NOKOGIRI = "--use-system-libraries";
      DISABLE_SPRING = "1";
      LD_LIBRARY_PATH = lib.makeLibraryPath [ vips pkgs.imagemagick ];
    } // lib.optionalAttrs cfg.postgres.enable {
      BUNDLE_BUILD__PG = "--with-pg-config=${lib.getExe' cfg.postgres.package.pg_config "pg_config"}";
      # devenv's managed postgres listens socket-only and sets PGHOST to
      # ${DEVENV_RUNTIME}/postgres; mirror that so DATABASE_URL resolves
      # against the managed instance's unix socket.
      PGHOST = "${config.env.DEVENV_RUNTIME}/postgres";
      DATABASE_URL = "postgresql:///";
    } // lib.optionalAttrs cfg.redis.enable {
      REDIS_URL = "redis://localhost:6379";
    } // cfg.extraEnv;

    services.postgres = lib.mkIf cfg.postgres.enable {
      enable = true;
      package = cfg.postgres.package;
      listen_addresses = "";  # socket-only; PGHOST -> ${DEVENV_RUNTIME}/postgres
    };
    services.redis.enable = cfg.redis.enable;

    enterShell = ''
      # Gemfile shadow — strip the `ruby "X.Y.Z"` pin so bundler accepts the
      # nixpkgs patch version. Symlink the lockfile so `bundle install` writes
      # flow back to the canonical Gemfile.lock.
      if grep -q '^ruby "' Gemfile 2>/dev/null; then
        sed '/^ruby "/d' Gemfile > .Gemfile.nix
        ln -sf Gemfile.lock .Gemfile.nix.lock
        export BUNDLE_GEMFILE="$PWD/.Gemfile.nix"
      fi

      # Stale-gem guard — wipe .gems when the Ruby store prefix changes.
      ruby_prefix="$(ruby -e 'puts RbConfig::CONFIG["prefix"]')"
      ruby_stamp="$PWD/.gems/.ruby-prefix"
      if [ -d "$PWD/.gems" ] && [ -f "$ruby_stamp" ] && [ "$(cat "$ruby_stamp")" != "$ruby_prefix" ]; then
        echo "Ruby store path changed → wiping .gems (run 'bundle install' to rebuild)"
        rm -rf "$PWD/.gems"
      fi
      mkdir -p "$PWD/.gems"
      echo "$ruby_prefix" > "$ruby_stamp"

      # Local gems in a versioned subdir
      ruby_abi="$(ruby -e 'puts RbConfig::CONFIG["ruby_version"]')"
      export BUNDLE_PATH="$PWD/.gems"
      export GEM_HOME="$PWD/.gems/ruby/$ruby_abi"
      export GEM_PATH="$PWD/.gems/ruby/$ruby_abi"
      export PATH="$PWD/.gems/ruby/$ruby_abi/bin:$PWD/bin:$PATH"

      # Warn (don't block) when configured ruby ≠ .ruby-version major.minor
      if [ -f .ruby-version ]; then
        rv="$(tr -d 'ruby- \n' < .ruby-version | cut -d. -f1,2)"
        if [ -n "$rv" ] && [ "$rv" != "${cfg.ruby}" ]; then
          printf '\033[33m⚠ devenv: configured ruby ${cfg.ruby} ≠ .ruby-version (%s). Update digitpro.rails.ruby or .ruby-version.\033[0m\n' "$rv"
        fi
      fi
      echo "Rails devenv: Ruby $(ruby --version | cut -d' ' -f2) | Node $(node --version 2>/dev/null || echo n/a)"
    '';
  };
}
