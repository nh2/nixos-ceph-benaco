{ config, lib, pkgs, ... }:

with lib;

let
  ceph = pkgs.ceph-benaco;

  cfg = config.services.ceph-benaco;

  # Example:
  #   serviceUnitOf cfg.systemd.services.myservice == "myservice.service"
  serviceUnitOf = service: "${service._module.args.name}.service";

in

{

  ###### interface

  options = {

    services.ceph-benaco = {

      enable = mkEnableOption "Ceph distributed filesystem";

      fsid = mkOption {
        type = types.str;
        description = "Unique cluster identifier.";
      };

      clusterName = mkOption {
        type = types.str;
        description = "Cluster name.";
        default = "ceph";
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

      monitor = {
        enable = mkEnableOption "Activate a Ceph monitor on this machine.";

        initialKeyring = mkOption {
          type = types.path;
          description = "Keyring file to use when initializing a new monitor";
          example = "/path/to/ceph.mon.keyring";
        };

        nodeName = mkOption {
          type = types.str;
          description = "Ceph monitor node name.";
          example = "node1";
        };
      };

      manager = {
        enable = mkEnableOption "Activate a Ceph manager on this machine.";

        nodeName = mkOption {
          type = types.str;
          description = "Ceph manager node name.";
          example = "node1";
        };
      };

      osds = mkOption {
        default = {};
        example = {
          osd1 = {
            enable = true;
            bootstrapKeyring = "/path/to/ceph.client.bootstrap-osd.keyring";
            id = 1;
            uuid = "11111111-1111-1111-1111-111111111111";
            blockDevice = "/dev/sdb";
            blockDeviceUdevRuleMatcher = ''KERNEL=="sdb"'';
          };
          osd2 = {
            enable = true;
            bootstrapKeyring = "/path/to/ceph.client.bootstrap-osd.keyring";
            id = 2;
            uuid = "22222222-2222-2222-2222-222222222222";
            blockDevice = "/dev/sdc";
            blockDeviceUdevRuleMatcher = ''KERNEL=="sdc"'';
          };
        };
        description = ''
          This option allows you to define multiple Ceph OSDs.
          A common idiom is to use one OSD per physical hard drive.

          Note that the OSD names given as attributes of this key
          are NOT what ceph calls OSD IDs (instead, those are defined
          by the 'services.ceph-benaco.osds.*.id' fields).
          Instead, the name is an identifier local and unique to the
          current machine only, used only to name the systemd service
          for that OSD.
        '';
        type = types.attrsOf (types.submodule {
          options = {

            enable = mkEnableOption "Activate a Ceph OSD on this machine.";

            bootstrapKeyring = mkOption {
              type = types.path;
              description = "Ceph OSD bootstrap keyring.";
              example = "/path/to/ceph.client.bootstrap-osd.keyring";
            };

            id = mkOption {
              type = types.int;
              description = "The ID of this OSD. Must be unique in the Ceph cluster.";
              example = 1;
            };

            uuid = mkOption {
              type = types.str;
              description = "The UUID of this OSD. Must be unique in the Ceph cluster.";
              example = "abcdef12-abcd-1234-abcd-1234567890ab";
            };

            systemdExtraRequiresAfter = mkOption {
              type = types.listOf types.str;
              default = [];
              description = ''
                Add the specified systemd units to the "requires" and "after"
                lists of the systemd service of this OSD.

                Useful, for example, to decrypt the underlying block devices with LUKS first.

                NixOS modules allow override those lists from outside, but for that
                the names of the systemd services for the OSDs need to be known;
                this option is a convenience to not have to know them from outside.
              '';
              example = "decrypt-my-disk.service";
            };

            skipZap = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Whether to skip the zapping of the the OSD device on initial OSD
                installation.

                Skipping is needed because <command>ceph-volume</command> cannot
                zap device-mapper devices:
                <link xlink:href="https://tracker.ceph.com/issues/24504" />

                In that case you need to wipe the device manually.

                In the common case of placing the OSD on a cryptsetup LUKS device
                (which is a device-mapper device), re-creating the encryption
                from scratch with a new key zaps anything anyway, in which case
                zapping can be skipped here.
              '';
            };

            blockDevice = mkOption {
              type = types.str;
              description = "The block device used to store the OSD.";
              example = "/dev/sdb";
            };

            blockDeviceUdevRuleMatcher = mkOption {
              type = types.str;
              description = ''
                An udev rule matcher matching the block device used to store the OSD.
                Will be spliced into the udev rule that is
                used to set access permissions to the ceph user via an udev rule.

                This is a matcher instead of just a device name to allow flexibility:
                Normal disks can be easily matched with <code>KERNEL=="sda1"</code>, but
                device-mapper may not; for example, decrypted cryptsetup LUKS devices
                have a less useful <code>KERNEL=="dm-4"</code> and may better be matched
                using <code>ENV{DM_NAME}=="mydisk-decrypted"</code>.
              '';
              example = ''KERNEL=="sdb"'';
            };

            dbBlockDevice = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                The block device used to store the OSD's BlueStore DB device.

                Put this on a faster device than <option>blockDevice</option> to improve performance.

                See <link xlink:href="http://docs.ceph.com/docs/master/rados/configuration/bluestore-config-ref/" />
                for details.
              '';
              example = "/dev/sdc";
            };

            dbBlockDeviceUdevRuleMatcher = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Like <option>blockDeviceUdevRuleMatcher</option> but for the
                <option>dbBlockDevice</option>.
              '';
              example = ''KERNEL=="sdc"'';
            };

          };
        });
      };

      mds = {
        enable = mkEnableOption "Activate a Ceph MDS on this machine.";

        nodeName = mkOption {
          type = types.str;
          description = "Ceph MDS node name.";
          example = "node1";
        };
      };

      extraConfig = mkOption {
        type = types.str;
        default = "";
        description = ''
          Additional ceph.conf settings.

          See the sample file for inspiration:
          <link xlink:href="https://github.com/ceph/ceph/blob/master/src/sample.ceph.conf" />
        '';
      };
    };
  };

  ###### implementation

  config = let
    monDir = "/var/lib/ceph/mon/${cfg.clusterName}-${cfg.monitor.nodeName}";
    mgrDir = "/var/lib/ceph/mgr/${cfg.clusterName}-${cfg.manager.nodeName}";
    mdsDir = "/var/lib/ceph/mds/${cfg.clusterName}-${cfg.mds.nodeName}";

    # File permissions for things that are on locations wiped at start
    # (e.g. /run or its /var/run symlink).
    ensureTransientCephDirs = ''
      install -m 770 -o ${config.users.users.ceph.name} -g ${config.users.groups.ceph.name} -d /var/run/ceph
    '';

    # File permissions from cluster deployed with ceph-deploy.
    ensureCephDirs = ''
      install -m 3770 -o ${config.users.users.ceph.name} -g ${config.users.groups.ceph.name} -d /var/log/ceph
      install -m 770 -o ${config.users.users.ceph.name} -g ${config.users.groups.ceph.name} -d /var/run/ceph
      install -m 750 -o ${config.users.users.ceph.name} -g ${config.users.groups.ceph.name} -d /var/lib/ceph
      install -m 755 -o ${config.users.users.ceph.name} -g ${config.users.groups.ceph.name} -d /var/lib/ceph/mon
      install -m 755 -o ${config.users.users.ceph.name} -g ${config.users.groups.ceph.name} -d /var/lib/ceph/mgr
      install -m 755 -o ${config.users.users.ceph.name} -g ${config.users.groups.ceph.name} -d /var/lib/ceph/osd
    '';

    makeCephOsdSetupSystemdService = localOsdServiceName: osdConfig:
    let
      osdExistenceFile = "/var/lib/ceph/osd/.${toString osdConfig.id}.${osdConfig.uuid}.nix-existence";
    in
    mkIf osdConfig.enable {
      description = "Initialize Ceph OSD";

      requires = osdConfig.systemdExtraRequiresAfter;
      after = osdConfig.systemdExtraRequiresAfter;

      # TODO Use `udevadm trigger --settle` instead of the separate `udevadm settle`
      #      once that feature is available to us with systemd >= 238;
      #      see https://github.com/systemd/systemd/commit/792cc203a67edb201073351f5c766fce3d5eab45
      preStart = ''
        set -x
        ${ensureCephDirs}
        install -m 755 -o ${config.users.users.ceph.name} -g ${config.users.groups.ceph.name} -d /var/lib/ceph/bootstrap-osd
        # `install` is not atomic, see
        # https://lists.gnu.org/archive/html/bug-coreutils/2010-02/msg00243.html
        # so use `mktemp` + `mv` to make it atomic.
        TMPFILE=$(mktemp --tmpdir=/var/lib/ceph/bootstrap-osd/)
        install -o ${config.users.users.ceph.name} -g ${config.users.groups.ceph.name} ${osdConfig.bootstrapKeyring} "$TMPFILE"
        mv "$TMPFILE" /var/lib/ceph/bootstrap-osd/ceph.keyring

        # Trigger udev rules for permissions of block devices and wait for them to settle.
        udevadm trigger --name-match=${osdConfig.blockDevice}
      '' + lib.optionalString (osdConfig.dbBlockDevice != null) ''
        udevadm trigger --name-match=${osdConfig.dbBlockDevice}
      '' +
      ''
        udevadm settle
      '' + (optionalString (!osdConfig.skipZap) (
        ''
          # Zap OSD block devices, otherwise `ceph-osd` below will try to fsck if there's some old
          # ceph data on the block device (see https://tracker.ceph.com/issues/24099).
          ${ceph}/bin/ceph-volume lvm zap ${osdConfig.blockDevice}
        '' + lib.optionalString (osdConfig.dbBlockDevice != null) ''
          ${ceph}/bin/ceph-volume lvm zap ${osdConfig.dbBlockDevice}
        ''
      ));

      script = ''
        set -euo pipefail
        set -x
        until [ -f /etc/ceph/ceph.client.admin.keyring ]
        do
          sleep 1
        done

        OSD_SECRET=$(${ceph}/bin/ceph-authtool --gen-print-key)
        echo "{\"cephx_secret\": \"$OSD_SECRET\"}" | \
          ${ceph}/bin/ceph osd new ${osdConfig.uuid} ${toString osdConfig.id} -i - \
          -n client.bootstrap-osd -k ${osdConfig.bootstrapKeyring}
        mkdir -p /var/lib/ceph/osd/${cfg.clusterName}-${toString osdConfig.id}

        ln -s ${osdConfig.blockDevice} /var/lib/ceph/osd/${cfg.clusterName}-${toString osdConfig.id}/block
      '' + lib.optionalString (osdConfig.dbBlockDevice != null) ''
        ln -s ${osdConfig.dbBlockDevice} /var/lib/ceph/osd/${cfg.clusterName}-${toString osdConfig.id}/block.db
      '' +
      ''

        ${ceph}/bin/ceph-authtool --create-keyring /var/lib/ceph/osd/ceph-${toString osdConfig.id}/keyring \
          --name osd.${toString osdConfig.id} --add-key $OSD_SECRET

        ${ceph}/bin/ceph-osd -i ${toString osdConfig.id} --mkfs --osd-uuid ${osdConfig.uuid} --setuser ${config.users.users.ceph.name} --setgroup ${config.users.groups.ceph.name} --osd-objectstore bluestore
        touch ${osdExistenceFile}
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        PermissionsStartOnly = true; # only run the script as ceph, preStart as root
        User = config.users.users.ceph.name;
        Group = config.users.groups.ceph.name;
      };
      unitConfig = {
        ConditionPathExists = "!${osdExistenceFile}";
      };
    };

    makeCephOsdSystemdService = localOsdServiceName: osdConfig: mkIf osdConfig.enable {
      description = "Ceph OSD";

      # Note we do not have to add `osdConfig.systemdExtraRequiresAfter` here because
      # that's already a dependency of our dependency `ceph-osd-setup-*`.
      requires = [
        (serviceUnitOf config.systemd.services."ceph-osd-setup-${localOsdServiceName}")
      ];
      requiredBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "local-fs.target"
        "time-sync.target"
        (serviceUnitOf config.systemd.services."ceph-osd-setup-${localOsdServiceName}")
      ];
      wants = [
        "network.target"
        "local-fs.target"
        "time-sync.target"
      ];

      path = [ pkgs.getopt ]; # TODO: use wrapProgram in the ceph package for this in the future

      restartTriggers = [ config.environment.etc."ceph/ceph.conf".source ];

      preStart = ''
        ${ensureTransientCephDirs}
        ${ceph}/libexec/ceph/ceph-osd-prestart.sh --cluster ${cfg.clusterName} --id ${toString osdConfig.id}
      '';

      serviceConfig = {
        LimitNOFILE="1048576";
        LimitNPROC="1048576";

        ExecStart=''
          ${ceph}/bin/ceph-osd -f --cluster ${cfg.clusterName} --id ${toString osdConfig.id} --setuser ${config.users.users.ceph.name} --setgroup ${config.users.groups.ceph.name}
        '';
        ExecReload=''
          ${pkgs.coreutils}/bin/kill -HUP $MAINPID
        '';
        Restart="on-failure";
        ProtectHome="true";
        ProtectSystem="full";
        PrivateTmp="true";
        TasksMax="infinity";
        # StartLimitInterval="30min";
        # StartLimitBurst="3";
      };
    };

  in mkIf cfg.enable {
    environment.systemPackages = [ ceph ];

    # See https://github.com/ceph/ceph/blob/master/src/sample.ceph.conf
    environment.etc."ceph/ceph.conf".text =
      let commaSep = builtins.concatStringsSep ",";
      in ''
        [global]
        fsid = ${cfg.fsid}
        mon initial members = ${commaSep (map (mon: mon.hostname) cfg.initialMonitors)}
        mon host = ${commaSep (map (mon: mon.ipAddress) cfg.initialMonitors)}
        public network = ${commaSep cfg.publicNetworks}
        auth cluster required = cephx
        auth service required = cephx
        auth client required = cephx

        ${cfg.extraConfig}
      '';

    environment.etc."ceph/ceph.client.admin.keyring" = {
      source = cfg.adminKeyring;
      mode = "0600";
      # Make ceph own this keyring so that it can use it to get keys for its daemons.
      user = "ceph";
      group = "ceph";
    };

    users.extraGroups.ceph = {
      members = [ "ceph" ];
    };

    users.extraUsers.ceph = {
    };

    # The udevadm trigger/settle in `makeCephOsdSetupSystemdService` waits for these rules rule to be applied.
    services.udev.extraRules =
      lib.concatStringsSep "\n" (
        lib.mapAttrsToList (_localOsdServiceName: osdConfig:
          ''
            SUBSYSTEM=="block", ${osdConfig.blockDeviceUdevRuleMatcher}, OWNER="${config.users.users.ceph.name}", GROUP="${config.users.groups.ceph.name}", MODE="0660"
          ''
          + lib.optionalString (osdConfig.dbBlockDeviceUdevRuleMatcher != null) (
              ''
                SUBSYSTEM=="block", ${osdConfig.dbBlockDeviceUdevRuleMatcher}, OWNER="${config.users.users.ceph.name}", GROUP="${config.users.groups.ceph.name}", MODE="0660"
              ''
            )
        ) cfg.osds
      );

    systemd.services = {

      ceph-mon-setup = mkIf cfg.monitor.enable {
        description = "Initialize ceph monitor";

        preStart = ensureCephDirs;

        script = let
          monmapNodes = builtins.concatStringsSep " " (lib.concatMap (mon: [ "--add" mon.hostname mon.ipAddress ]) cfg.initialMonitors);
        in ''
          set -euo pipefail
          rm -rf "${monDir}" # Start from scratch.
          echo "Initializing monitor."
          MONMAP_DIR=`mktemp -d`
          ${ceph}/bin/monmaptool --create ${monmapNodes} --fsid ${cfg.fsid} "$MONMAP_DIR/monmap"
          ${ceph}/bin/ceph-mon --cluster ${cfg.clusterName} --mkfs -i ${cfg.monitor.nodeName} --monmap "$MONMAP_DIR/monmap" --keyring ${cfg.monitor.initialKeyring}
          rm -r "$MONMAP_DIR"
          touch ${monDir}/done
        '';

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          PermissionsStartOnly = true; # only run the script as ceph
          User = config.users.users.ceph.name;
          Group = config.users.groups.ceph.name;
        };
        unitConfig = {
          ConditionPathExists = "!${monDir}/done";
        };
      };

      ceph-mon = mkIf cfg.monitor.enable {
        description = "Ceph monitor";

        requires = [ (serviceUnitOf config.systemd.services.ceph-mon-setup) ];
        requiredBy = [ "multi-user.target" ];
        after = [ "network.target" "local-fs.target" "time-sync.target" (serviceUnitOf config.systemd.services.ceph-mon-setup) ];
        wants = [ "network.target" "local-fs.target" "time-sync.target" ];

        restartTriggers = [ config.environment.etc."ceph/ceph.conf".source ];

        preStart = ensureTransientCephDirs;

        serviceConfig = {
          LimitNOFILE="1048576";
          LimitNPROC="1048576";
          ExecStart=''
            ${ceph}/bin/ceph-mon -f --cluster ${cfg.clusterName} --id ${cfg.monitor.nodeName} --setuser ${config.users.users.ceph.name} --setgroup ${config.users.groups.ceph.name}
          '';
          ExecReload=''
            ${pkgs.coreutils}/bin/kill -HUP $MAINPID
          '';
          PrivateDevices="yes";
          ProtectHome="true";
          ProtectSystem="full";
          PrivateTmp="true";
          TasksMax="infinity";
          Restart="on-failure";
          # StartLimitInterval="30min";
          # StartLimitBurst="5";
          RestartSec="10";
        };
      };

      ceph-mgr-setup = mkIf cfg.manager.enable {
        description = "Initialize Ceph manager";

        preStart = ensureCephDirs;

        script = ''
          set -euo pipefail
          mkdir -p ${mgrDir}
          until [ -f /etc/ceph/ceph.client.admin.keyring ]
          do
            sleep 1
          done
          ${ceph}/bin/ceph auth get-or-create mgr.${cfg.manager.nodeName} mon 'allow profile mgr' mds 'allow *' osd 'allow *' -o ${mgrDir}/keyring
          touch "${mgrDir}/.nix_done"
        '';

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          PermissionsStartOnly = true; # only run the script as ceph
          User = config.users.users.ceph.name;
          Group = config.users.groups.ceph.name;
        };
        unitConfig = {
          ConditionPathExists = "!${mgrDir}/.nix_done";
        };
      };

      ceph-mgr = mkIf cfg.manager.enable {
        description = "Ceph manager";

        requires = [ (serviceUnitOf config.systemd.services.ceph-mgr-setup) ];
        requiredBy = [ "multi-user.target" ];
        after = [ "network.target" "local-fs.target" "time-sync.target" (serviceUnitOf config.systemd.services.ceph-mgr-setup) ];
        wants = [ "network.target" "local-fs.target" "time-sync.target" ];

        restartTriggers = [ config.environment.etc."ceph/ceph.conf".source ];

        preStart = ensureTransientCephDirs;

        serviceConfig = {
          LimitNOFILE="1048576";
          LimitNPROC="1048576";

          ExecStart=''
            ${ceph}/bin/ceph-mgr -f --cluster ${cfg.clusterName} --id ${cfg.manager.nodeName} --setuser ${config.users.users.ceph.name} --setgroup ${config.users.groups.ceph.name}
          '';
          ExecReload=''
            ${pkgs.coreutils}/bin/kill -HUP $MAINPID
          '';
          Restart="on-failure";
          RestartSec=10;
          # StartLimitInterval="30min";
          # StartLimitBurst="3";
        };
      };

      ceph-mds-setup = mkIf cfg.mds.enable {
        description = "Initialize Ceph MDS";

        preStart = ensureCephDirs;

        script = ''
          set -euo pipefail
          mkdir -p ${mdsDir}
          until [ -f /etc/ceph/ceph.client.admin.keyring ]
          do
            sleep 1
          done
          ${ceph}/bin/ceph auth get-or-create mds.${cfg.mds.nodeName} osd 'allow rwx' mds 'allow' mon 'allow profile mds' -o ${mdsDir}/keyring
          touch "${mdsDir}/.nix_done"
        '';

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          PermissionsStartOnly = true; # only run the script as ceph
          User = config.users.users.ceph.name;
          Group = config.users.groups.ceph.name;
        };
        unitConfig = {
          ConditionPathExists = "!${mdsDir}/.nix_done";
        };
      };

      ceph-mds = mkIf cfg.mds.enable {
        description = "Ceph MDS";

        requires = [ (serviceUnitOf config.systemd.services.ceph-mds-setup) ];
        requiredBy = [ "multi-user.target" ];
        after = [ "network.target" "local-fs.target" "time-sync.target" (serviceUnitOf config.systemd.services.ceph-mds-setup) ];
        wants = [ "network.target" "local-fs.target" "time-sync.target" ];

        restartTriggers = [ config.environment.etc."ceph/ceph.conf".source ];

        preStart = ensureTransientCephDirs;

        serviceConfig = {
          LimitNOFILE="1048576";
          LimitNPROC="1048576";

          ExecStart=''
            ${ceph}/bin/ceph-mds -f --cluster ${cfg.clusterName} --id ${cfg.mds.nodeName} --setuser ${config.users.users.ceph.name} --setgroup ${config.users.groups.ceph.name}
          '';
          ExecReload=''
            ${pkgs.coreutils}/bin/kill -HUP $MAINPID
          '';
          Restart="on-failure";
          # StartLimitInterval="30min";
          # StartLimitBurst="3";
        };
      };

    }
      # Make one OSD service for each configured OSD.
      // lib.mapAttrs' (localOsdServiceName: osdConfig: nameValuePair "ceph-osd-setup-${localOsdServiceName}" (makeCephOsdSetupSystemdService localOsdServiceName osdConfig)) cfg.osds
      // lib.mapAttrs' (localOsdServiceName: osdConfig: nameValuePair "ceph-osd-${localOsdServiceName}"       (makeCephOsdSystemdService      localOsdServiceName osdConfig)) cfg.osds;
  };
}
