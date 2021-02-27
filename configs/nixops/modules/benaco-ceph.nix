{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.benaco-ceph-server;

  # Example:
  #   serviceUnitOf cfg.systemd.services.myservice == "myservice.service"
  serviceUnitOf = service: "${service._module.args.name}.service";
in {
  imports = [
    ./ceph-benaco.nix
  ];

  options = {
    services.benaco-ceph-server = {
      enable = mkEnableOption "Enable Ceph server daemons on this machine.";

      fsid = mkOption {
        type = types.str;
        description = "Unique cluster identifier.";
      };

      nodeName = mkOption {
        type = types.str;
        description = "Ceph node name.";
      };

      initialMonitors = mkOption {
        type = types.listOf (types.submodule {
          options = {
            hostname = mkOption {
              type = types.str;
              description = "Initial monitor hostname.";
            };

            ipAddress = mkOption {
              type = types.str;
              description = "Initial monitor IP address.";
            };
          };
        });
        description = "Initial monitors.";
      };

      publicNetworks = mkOption {
        type = types.listOf types.str;
        description = "Public network(s) of the cluster.";
      };

      adminKeyring = mkOption {
        type = types.path;
        description = "Ceph admin keyring to install on the machine.";
      };

      initialMonitorKeyring = mkOption {
        type = types.path;
        description = "Keyring file to use when initializing a new monitor";
      };

      osdBootstrapKeyring = mkOption {
        type = types.path;
        description = "Ceph OSD bootstrap keyring.";
      };

      osdUuid = mkOption {
        type = types.str;
        description = "The UUID of this OSD.";
      };
    };
  };

  config = mkIf cfg.enable {
    services.ceph-benaco = {
      enable = true;
      fsid = cfg.fsid;
      nodeName = cfg.nodeName;
      initialMonitors = cfg.initialMonitors;
      publicNetworks = cfg.publicNetworks;
      adminKeyring = cfg.adminKeyring;

      monitor = {
        enable = true;
        initialKeyring = cfg.initialMonitorKeyring;
      };

      manager = {
        enable = true;
      };

      osd = {
        enable = true;
        bootstrapKeyring = cfg.osdBootstrapKeyring;
        uuid = cfg.osdUuid;
      };

      mds = {
        enable = true;
      };

      extraConfig = ''
        # Speed up recovery (explained at http://tracker.ceph.com/issues/23595#note-8)
        # We want this in general, independent of Ceph bugs 23595 or 23141,
        # because the default sleeps are way too high for fast recoveries.
        osd_recovery_sleep = 0
        osd_recovery_sleep_hdd = 0
        osd_recovery_sleep_hybrid = 0
        osd_recovery_sleep_ssd = 0

        osd_max_backfills 100
      '';
    };

    # Start ceph-mon after Tinc.
    systemd.services.ceph-mon-setup.requires = [ (serviceUnitOf config.systemd.services.consulReady ) ];
    systemd.services.ceph-mon-setup.after = [ (serviceUnitOf config.systemd.services.consulReady ) ];
  };
}
