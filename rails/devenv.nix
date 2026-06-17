{ lib, pkgs, config, ... }:
let
  cfg = config.digitpro.rails;
  nodePkg = { "22" = pkgs.nodejs_22; "24" = pkgs.nodejs_24; }.${cfg.node.version};
  vips =
    if pkgs.stdenv.isDarwin
    then (pkgs.vips.override { matio = null; withIntrospection = false; }).overrideAttrs
           (prev: { mesonFlags = (prev.mesonFlags or []) ++ [ "-Dmatio=disabled" ]; })
    else pkgs.vips;
in {
  options.digitpro.rails = {
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
    # Exact Ruby patch from the CONSUMER's .ruby-version, via devenv's
    # nixpkgs-ruby integration (requires the `nixpkgs-ruby` flake input).
    # config.devenv.root is the consumer project root (requires --impure).
    # `.ruby-version` is the single source of truth for the Ruby version.
    # mkDefault lets the flake checks pin the version directly with mkForce.
    # If `.ruby-version` is absent the module fails with a clear path in the error.
    languages.ruby = {
      enable = true;
      version = lib.mkDefault (lib.removePrefix "ruby-"
        (lib.fileContents "${config.devenv.root}/.ruby-version"));
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
      ++ lib.optional cfg.devenvUp.enable pkgs.foreman
      ++ cfg.extraPackages;

    processes = lib.mkIf cfg.devenvUp.enable {
      app.exec = "exec foreman start -f Procfile.dev";
    };

    env = {
      LD_LIBRARY_PATH = lib.makeLibraryPath [ vips pkgs.imagemagick ];
    } // lib.optionalAttrs cfg.postgres.enable {
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
  };
}
