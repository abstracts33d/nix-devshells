{
  pkgs,
  lib,
  legacyPkgs ? null,
  ...
}: {
  # Ruby — set package directly from nixpkgs (avoids nixpkgs-ruby input)
  # Modern: pkgs.ruby_3_4, pkgs.ruby_3_3, pkgs.ruby_3_2
  # Legacy: bootstrap.sh sets legacyPkgs.ruby_2_7 or legacyPkgs.ruby_2_6
  languages.ruby = {
    enable = true;
    package =
      if legacyPkgs != null
      then legacyPkgs.ruby_2_7
      else pkgs.ruby_3_4;
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

  # Services — managed per-project, no system-level dependency
  services.postgres = {
    enable = true;
    listen_addresses = "127.0.0.1";
  };
  services.redis.enable = true;

  # Environment
  env = {
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

    # Local gems — keep gems per-project, not in nix store
    export GEM_HOME="$PWD/.gems"
    export GEM_PATH="$PWD/.gems"
    export BUNDLE_PATH="$PWD/.gems"
    export PATH="$PWD/.gems/bin:$PWD/bin:$PATH"

    echo "Rails devenv: Ruby $(ruby --version | cut -d' ' -f2) | Node $(node --version)"
  '';
}
