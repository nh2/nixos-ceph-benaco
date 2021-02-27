{ config, pkgs, ... }:

with pkgs.lib;

let
  cfg = config.secrets;
in {

  imports = [
  ];

  options = {

    secrets = {

      secretsDirName = mkOption {
        type = types.str;
        description = ''
          Name of the dir (relative to where nixops is run) in which the
          secret files (SSL privkeys etc) are
        '';
      };

      secretsDirPathString = mkOption {
        type = types.str;
        description = ''
          Absolute path to dir in which the secret files (SSL privkeys etc) are.
          This is NOT a ./path because paths easily go into the nix store.
        '';
        # Using `toString` here immediately ensures that the path doesn't go
        # into the nix store.
        default = toString (../. + "/${cfg.secretsDirName}");
      };

      readSecretGoingIntoStore = mkOption {
        type = types.unspecified; # it's a function, there is no type for that
        description = ''
          Function that, given a relative path of a secret, reads and returns
          the file contents.
          This function may put the file contents into the nix store.
        '';
        default = secretPath: builtins.readFile (../. + "/${cfg.secretsDirName}/${secretPath}");
      };

    };

  };

}
