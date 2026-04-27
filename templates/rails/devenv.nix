{
  pkgs,
  lib,
  ...
}: {
  # Ruby — set package directly from nixpkgs (avoids nixpkgs-ruby input)
  # bootstrap.sh patches this to match .ruby-version (e.g., pkgs.ruby_3_3)
  languages.ruby = {
    enable = true;
    package = pkgs.ruby_3_4;
  };

  # Node.js + Yarn for asset pipeline
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_22;
    yarn.enable = true;
  };

  # Native libraries for gem compilation
  packages = with pkgs; [
    postgresql
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
    rustc
    cargo
    overmind
    pgcli
    iredis
  ];

  # Environment
  env = {
    PGHOST = "/run/postgresql";
    DATABASE_URL = "postgresql:///";
    REDIS_URL = "redis://localhost:6379";
    BUNDLE_BUILD__PG = "--with-pg-config=${lib.getExe' pkgs.postgresql "pg_config"}";
    BUNDLE_BUILD__NOKOGIRI = "--use-system-libraries";
    DISABLE_SPRING = "1";
  };

  # Shell startup
  enterShell = ''
    # Gemfile shadow — strip ruby version constraint so bundler
    # accepts the nixpkgs patch version (e.g., 3.4.4 vs pinned 3.4.2)
    if grep -q '^ruby "' Gemfile 2>/dev/null; then
      sed '/^ruby "/d' Gemfile > .Gemfile.nix
      export BUNDLE_GEMFILE="$PWD/.Gemfile.nix"
    fi

    # Stale-gem guard — when nixpkgs bumps Ruby, native extensions in .gems
    # (openssl.bundle, nokogiri, pg, ...) still link to the previous libruby
    # in /nix/store, which gets garbage-collected. Detect a Ruby prefix
    # change and wipe .gems so `bundle install` rebuilds against current Ruby.
    ruby_prefix="$(ruby -e 'puts RbConfig::CONFIG["prefix"]')"
    ruby_stamp="$PWD/.gems/.ruby-prefix"
    if [ -d "$PWD/.gems" ] && [ -f "$ruby_stamp" ] && [ "$(cat "$ruby_stamp")" != "$ruby_prefix" ]; then
      echo "Ruby store path changed → wiping .gems (run 'bundle install' to rebuild)"
      rm -rf "$PWD/.gems"
    fi
    mkdir -p "$PWD/.gems"
    echo "$ruby_prefix" > "$ruby_stamp"

    # Local gems — keep gems per-project, not in nix store
    export GEM_HOME="$PWD/.gems"
    export GEM_PATH="$PWD/.gems"
    export BUNDLE_PATH="$PWD/.gems"
    export PATH="$PWD/.gems/bin:$PWD/bin:$PATH"

    echo "Rails devenv: Ruby $(ruby --version | cut -d' ' -f2) | Node $(node --version)"
  '';
}
