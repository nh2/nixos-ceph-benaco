{ config, pkgs, ... }:

with pkgs.lib;

let
in {

  imports = [
  ];

  options = {

    ipInfo = {

      publicIp = mkOption {
        type = types.str;
        description = ''Public IP address of the machine.'';
        example = "1.2.3.4";
      };

    };

  };

  config = {};

}
