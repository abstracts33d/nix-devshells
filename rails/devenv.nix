{ lib, pkgs, config, ... }:
let
  cfg = config.digitpro.rails;
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
    # filled in by later tasks
  };
}
