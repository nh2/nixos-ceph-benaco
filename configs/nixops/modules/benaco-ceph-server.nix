{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.benaco-ceph-server;

  # Example:
  #   serviceUnitOf cfg.systemd.services.myservice == "myservice.service"
  serviceUnitOf = service: "${service._module.args.name}.service";

  ceph = pkgs.ceph-benaco;
in {
  imports = [
    ./ceph-benaco.nix
  ];

  options = {
    services.benaco-ceph-server = {
      enable = mkEnableOption "Enable Ceph server daemons on this machine.";

      nodeName = mkOption {
        type = types.str;
        description = "The node name to use for the monitor, manager and MDS daemons.";
        example = "node1";
      };

      initialMonitorKeyring = mkOption {
        type = types.path;
        description = "Keyring file to use when initializing a new monitor";
        example = "/path/to/ceph/ceph.mon.keyring";
      };
    };
  };

  config = mkIf cfg.enable {
    services.ceph-benaco = {
      monitor = {
        enable = true;
        initialKeyring = cfg.initialMonitorKeyring;
        nodeName = cfg.nodeName;
      };

      manager = {
        enable = true;
        nodeName = cfg.nodeName;
      };

      mds = {
        enable = true;
        nodeName = cfg.nodeName;
      };
    };

    # Start ceph-mon after Tinc.
    systemd.services.ceph-mon-setup.requires = [ (serviceUnitOf config.systemd.services.consulReady ) ];
    systemd.services.ceph-mon-setup.after = [ (serviceUnitOf config.systemd.services.consulReady ) ];

    # For administration
    environment.systemPackages = [
      ceph
    ];
  };
}
