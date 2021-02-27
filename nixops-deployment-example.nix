{
  deployToAws ? false,
  awsKeyId ? "benaco-nixops" # symbolic name looked up in ~/.ec2-keys or a ~/.aws/credentials profile name
}:
let
  # Generated with:
  #     $(../../benaco-nix nix-build --no-out-link -E 'with import <nixpkgs> {}; pkgs.callPackage ./generateSecrets.nix { }') "secrets-corp"
  secretsDirName = "secrets-corp";

  benacofs_files_dir = "/shared/corp";

  vpnNetworkName = "benacovpn";

  pkgs = (import <nixpkgs> {});
  lib = pkgs.lib;

  # This is a bit ugly because we have to return a function that accepts
  # `nodes`, which we can pass only from inside a machine config.
  mkTincServiceConfigFunction = { tincName, vpnIPAddress }: { config, nodes }:
  {
    enable = true;
    vpnNetworkName = vpnNetworkName;
    tincName = tincName;
    vpnIPAddress = vpnIPAddress;
    publicKey = config.secrets.readSecretGoingIntoStore "tinc/ed25519_key.pub";
    # This file can be generated with e.g.
    #   nix-shell -p "tinc_pre" --pure --run 'tinc generate-ed25519-keys'
    privateKey = config.secrets.readSecretGoingIntoStore "tinc/ed25519_key.priv";
    allTincHosts = map ({ netInfo }: {
      host = nodes."${netInfo.hostName}".config.ipInfo.publicIp;
      inherit (netInfo) tincName vpnIPAddress;
    }) allVpnNodes;
  };

  defaultMachineConfigModule = { config, pkgs, ... }: {
    imports = [
      ./modules/benaco-common-server-settings.nix

      ./modules/secrets.nix
    ];

    options = with pkgs.lib; {

      netInfo = {

        hostName = mkOption {
          type = types.str;
          description = ''Host name of the machine.'';
          example = "my-node-1";
        };

        tincName = mkOption {
          type = types.str;
          description = ''tinc node name for use in `hosts` config, may have underscores but no hyphens'';
          example = "my_node_1";
        };

        vpnIPAddress = mkOption {
          type = types.str;
          description = ''IP address in our tinc VPN'';
          example = "10.0.0.1";
        };

        dnsFqdn = mkOption {
          type = types.nullOr types.str;
          description = ''Full public DNS entry leading directly to this machine'';
          example = "my-node-1.example.com";
        };

      };

    };

    config = {
      # Overlays for nixops machines have to be explicitly declared.
      # See https://github.com/NixOS/nixops/issues/893
      nixpkgs.overlays = [
        (import ../../nix-channel/nixpkgs-overlays/default.nix)
      ];

      secrets.secretsDirName = secretsDirName;

      # SSH
      services.openssh.enable = true;

      networking.firewall = {
        # Reject instead of drop.
        rejectPackets = true;
        logRefusedConnections = false; # Helps with auth brueforce log spam.
        allowedTCPPorts = [
        ];
      };

      # Allow core dumps
      systemd.extraConfig = ''
        # core dump limit in KB
        DefaultLimitCORE=1000000
      '';

      users.extraUsers.root.openssh.authorizedKeys.keys = (import ./ssh-keys.nix);

      # zsh prompt colour; requires zsh setup from `benaco-common-server-settings.nix`.
      programs.zsh.interactiveShellInit = ''
        zstyle ':prompt:grml:left:items:user' pre '%F{green}%B'
      '';

    };

  };

  makeSecurityGroup = { region }: {
    accessKeyId = awsKeyId;
    inherit region;
    name = "nixops-corp-test-2";
    description = "nixops-corp-test-2";
    rules = [
      # Note: IPv6 entries likely won't work:
      #         * https://github.com/NixOS/nixops/issues/683
      { protocol = "tcp"; fromPort = 22; toPort = 22; sourceIp = "0.0.0.0/0"; } # ssh
      { protocol = "tcp"; fromPort = 80; toPort = 80; sourceIp = "0.0.0.0/0"; } # http
      { protocol = "tcp"; fromPort = 443; toPort = 443; sourceIp = "0.0.0.0/0"; } # https
      { protocol = "tcp"; fromPort = 655; toPort = 655; sourceIp = "0.0.0.0/0"; } # tinc
      { protocol = "udp"; fromPort = 655; toPort = 655; sourceIp = "0.0.0.0/0"; } # tinc
      { protocol = "tcp"; fromPort = 5201; toPort = 5201; sourceIp = "0.0.0.0/0"; } # iperf3
      { protocol = "icmp"; typeNumber = -1; codeNumber = -1; sourceIp = "0.0.0.0/0"; } # ping
    ];
  };

  # All regions that we use.
  #
  # [Note: Region completeness]
  #
  # Listing them here once, and referring to them only through this attrset,
  # ensures that each of them has an EC2 Security Group allocated below.
  ec2RegionsUsed = {
    "eu-central-1" = "eu-central-1";
    "eu-west-1" = "eu-west-1";
    "ap-southeast-1" = "ap-southeast-1";
  };

  # Note that the "resource name" (index into `resources.ec2SecurityGroups`)
  # is different from the security group name
  # (`resources.ec2SecurityGroups.someResourceName.name`).
  # `deployment.ec2.securityGroups` demands the latter, or a whole
  # `resources.ec2SecurityGroups` entry `ec2-security-group` object.
  securityGroupResourceNameForRegion = region:
    # Going via `ec2RegionsUsed`; see [Note: Region completeness]
    "nixops-corp-test-2-${ec2RegionsUsed."${region}"}";

  mkHetznerSX133_10x16TB_with2x960GBssds_physicalSpecModule = { ip, robotSubAccount }: { config, ... }: {

    imports = [
      ./modules/ipInfo.nix
    ];

    config = {
      deployment.targetEnv = "hetzner";

      deployment.hetzner.mainIPv4 = ip;
      deployment.hetzner.robotUser = robotSubAccount;
      deployment.hetzner.createSubAccount = false;
      deployment.hetzner.partitions = null;
      deployment.hetzner.partitioningScript = ''
        set -x
        set -euo pipefail

        # Stop RAID devices if running, otherwise we can't modify the disks below.
        test -b /dev/md0 && mdadm --stop /dev/md0

        # Zero out SSDs with TRIM command, so that `lazy_journal_init=1` can be safely used below.
        blkdiscard /dev/nvme0n1
        blkdiscard /dev/nvme1n1

        # Custom parted version
        # TODO Remove this once the patch included in this is merged and available (that is, parted >= 3.3, e.g. in Debian 11).
        curl -L https://github.com/nh2/parted/releases/download/v3.3/parted-v3.3-static-x86_64.tar.gz | tar xzv
        mv parted /usr/local/bin/
        hash -r

        # Partitions
        #
        # Create BIOS boot partition and main partition for each SSD and HDD.
        # Note Hetzner does use BIOS, not UEFI.
        # We use GPT because these disks could be too large for MSDOS partitions (e.g. 10TB disks).
        #
        # Note we use "MB" instead of "MiB" because otherwise `--align optimal` has no effect;
        # as per documentation https://www.gnu.org/software/parted/manual/html_node/unit.html#unit:
        # > Note that as of parted-2.4, when you specify start and/or end values using IEC
        # > binary units like "MiB", "GiB", "TiB", etc., parted treats those values as exact
        #
        # Note: When using `mkpart` on GPT, as per
        #   https://www.gnu.org/software/parted/manual/html_node/mkpart.html#mkpart
        # the first argument to `mkpart` is not a `part-type`, but the GPT partition name:
        #   ... part-type is one of 'primary', 'extended' or 'logical', and may be specified only with 'msdos' or 'dvh' partition tables.
        #   A name must be specified for a 'gpt' partition table.
        # GPT partition names are limited to 36 UTF-16 chars, see https://en.wikipedia.org/wiki/GUID_Partition_Table#Partition_entries_(LBA_2-33).
        #
        # SSDs; we place the BlueStore partition(s) last in case we want to change how many we have (as we add more OSDs)
        parted --script --align optimal /dev/nvme0n1 -- mklabel gpt mkpart 'BIOS-boot-partition-a' 1MB 2MB set 1 bios_grub on mkpart 'OS-partition-a' 2MB -500GB mkpart 'BlueStore-DB-partition-a' -500GB -400GB mkpart 'BlueStore-DB-partition-b' -400GB -300GB mkpart 'BlueStore-DB-partition-c' -300GB -200GB mkpart 'BlueStore-DB-partition-d' -200GB -100GB mkpart 'BlueStore-DB-partition-e' -100GB '100%'
        parted --script --align optimal /dev/nvme1n1 -- mklabel gpt mkpart 'BIOS-boot-partition-b' 1MB 2MB set 1 bios_grub on mkpart 'OS-partition-b' 2MB -500GB mkpart 'BlueStore-DB-partition-f' -500GB -400GB mkpart 'BlueStore-DB-partition-g' -400GB -300GB mkpart 'BlueStore-DB-partition-h' -300GB -200GB mkpart 'BlueStore-DB-partition-i' -200GB -100GB mkpart 'BlueStore-DB-partition-j' -100GB '100%'
        # HDDs
        for diskletter in {a..j}; do parted --script --align optimal /dev/sd"$diskletter" -- mklabel gpt mkpart "OSD-data-partition-$diskletter" 2MB '100%'; done

        # Now /dev/sd*1 is the one data partition

        # Reload partition table so Linux can see the changes
        partprobe

        # Wait for all partitions to exist
        for disk in /dev/disk/by-partlabel/BIOS-boot-partition-{a..b};    do udevadm settle --timeout=5 --exit-if-exists="$disk"; done
        for disk in /dev/disk/by-partlabel/OS-partition-{a..b};           do udevadm settle --timeout=5 --exit-if-exists="$disk"; done
        for disk in /dev/disk/by-partlabel/BlueStore-DB-partition-{a..j}; do udevadm settle --timeout=5 --exit-if-exists="$disk"; done
        for disk in /dev/disk/by-partlabel/OSD-data-partition-{a..j};     do udevadm settle --timeout=5 --exit-if-exists="$disk"; done

        # RAID1 for OS partition.
        # --run makes mdadm not prompt the user for confirmation
        # SSDs
        mdadm --create --run --verbose /dev/md0 --level=1 --raid-devices=2 /dev/disk/by-partlabel/OS-partition-{a..b}

        # Wipe filesystem signatures that might be on the RAID from some
        # possibly existing older use of the disks.
        # It's not clear to me *why* it is needed, but I have certainly
        # observed that it is needed because ext4 labels magically survive
        # mdadm RAID re-creations.
        # See
        #   https://serverfault.com/questions/911370/why-does-mdadm-zero-superblock-preserve-file-system-information
        # SSDs
        wipefs -a /dev/md0

        # Disable RAID recovery. We don't want this to slow down machine provisioning
        # in the Hetzner rescue mode. It can run in normal operation after reboot.
        echo 0 > /proc/sys/dev/raid/speed_limit_max

        mkfs.ext4 -F -L root /dev/md0
      '';
      deployment.hetzner.mountScript = ''
        set -e
        mount /dev/md0 /mnt
      '';
      deployment.hetzner.filesystemInfo = {
        swapDevices = [];
        boot.loader.grub.devices = [
          # List SSD devices only here because we're reasonably sure that those are
          # configured to be booted from in the BIOS for this type of server.
          "/dev/nvme0n1"
          "/dev/nvme1n1"
        ];
        fileSystems = {
          "/" = {
            fsType = "ext4";
            # We set the label with `mkfs.ext4 -L root` above.
            label = "root";
            options = [
              "errors=remount-ro"
            ];
          };
        };
      };

      ipInfo.publicIp = config.networking.publicIPv4;
    };
  };

  mkHetznerGpuServerWithSSDs_physicalSpecModule = { ip, robotSubAccount }: { config, ... }: {
    imports = [
      ./modules/ipInfo.nix
    ];

    config = {
      deployment.targetEnv = "hetzner";
      deployment.hetzner.createSubAccount = false; # because we use 2-factor auth
      deployment.hetzner.robotUser = robotSubAccount;
      deployment.hetzner.mainIPv4 = ip;
      deployment.hetzner.partitions = ''
        clearpart --all --initlabel --drives=sda,sdb

        part raid.1a --recommended --label=swap1 --fstype=swap --ondisk=sda
        part raid.1b --recommended --label=swap2 --fstype=swap --ondisk=sdb

        part raid.2a --grow --ondisk=sda
        part raid.2b --grow --ondisk=sdb

        raid swap --level=1 --device=swap --fstype=swap --label=swap raid.1a raid.1b
        raid /    --level=1 --device=root --fstype=ext4 --label=root raid.2a raid.2b
      '';

      ipInfo.publicIp = config.networking.publicIPv4;
    };
  };

  cephCommonConfig = {
    fsid = "b3697419-9725-416d-9b3d-a30e5b773be0";
    initialMonitors = [
      # `corp` stuff is on `10.1.*.*`.
      { hostname = "corpfs-1"; ipAddress = "10.1.3.1"; }
      # { hostname = "corpfs-2"; ipAddress = "10.1.3.2"; }
      # { hostname = "corpfs-3"; ipAddress = "10.1.3.3"; }
    ];
    publicNetworks = [ "10.1.3.0/24" ];
    adminKeyring = ./. + "/${secretsDirName}/ceph/ceph.client.admin.keyring";
    # Extra `ceph.conf` contents
    extraConfig = ''
      # Replication level, number of data copies. (Default: 3)
      osd pool default size = 1

      [mds]
      # Increase recall state timeout in hope of working around spurious
      #     Client ... failing to respond to cache pressure
      # health issues that resolve within a few seconds,
      # see #659#issuecomment-454357002
      # Disabled on corpfs for now, we don't know yet if this helps for
      # non-asset-serving workloads or makes them worse.
      #mds recall state timeout = 150

      # 10 GB metadata cache
      # * Improves asset serving latency significantly.
      # See #1326
      # From our research there, 1 file (inode) needs roughly 1 - 2.5 kB
      # metadata; the more is cached, the less disk seeks will be needed.
      mds cache memory limit = 10737418240

      [client]
      # Disable inode metadata cache.
      # * Reduces assets serving latency outliers by 10x (from up to 4 seconds).
      # See #1326
      # Disabled on corpfs for now, we don't know yet if this helps for
      # non-asset-serving workloads or makes them worse.
      #client cache size = 0
    '';
  };

  # We use our corpfs machines as consul servers for now.
  allConsensusServerHosts = map ({ netInfo, ... }: netInfo.vpnIPAddress) corpfsMachines;

  benacofsLuksKeyName = "corpfs-osd-luks-key";

  # Turns a device path, into the decrypted cryptsetup name
  # to appear in `/dev/mapper`.
  # Examples:
  #     /dev/disk/by-partlabel/BIOS-boot-partition-a -> BIOS-boot-partition-a-decrypted
  #     /dev/sda1 -> sda1-decrypted
  decryptedNameForDevice = fullDevicePath:
    lib.last (lib.splitString "/" fullDevicePath) + "-decrypted";

  mkCorpfsNode = { i, physicalSpecModule, cephOSDs }: rec {
    netInfo = {
      hostName = "corpfs-" + toString i; # host name, may have hyphens but no underscores
      tincName = "corpfs_" + toString i; # tinc node name for use in `hosts` config, may have underscores but no hyphens
      vpnIPAddress = "10.1.3.${toString i}"; # corpfs nodes are in 10.1.3.*; we support only up to 254 such nodes for now.
    };
    nodeConfig = { config, pkgs, lib, resources, nodes, ... }: # note: `pkgs` overrides the outer `pkgs` and contains the machine's final pkgs.
      rec {
        imports = [
          physicalSpecModule
          ./modules/benaco-tinc.nix
          ./modules/benaco-consul-over-tinc.nix
          ./modules/benaco-ceph-server.nix
          ./modules/benaco-ceph-client.nix
        ];

        inherit netInfo;

        # Tinc VPN
        services.benaco-tinc = mkTincServiceConfigFunction { inherit (netInfo) tincName vpnIPAddress; } { inherit config nodes; };

        # Consul
        services.benaco-consul-over-tinc = {
          enable = true;
          isServer = true; # TODO We only need a consul agent here, not a server.
          inherit allConsensusServerHosts;
          thisConsensusServerHost = config.services.benaco-tinc.vpnIPAddress;
        };

        # LUKS encryption at rest for ceph OSD block devices

        # Created with:
        #     dd if=/dev/urandom of=secrets-corp/corpfs-osd-luks-key bs=4K count=1
        deployment.keys.${benacofsLuksKeyName}.keyFile = ./. + "/${secretsDirName}/corpfs-osd-luks-key";

        systemd.services.benacofs-luks-format-or-open-osds = {
          requiredBy = [
            "multi-user.target" # we want this/nixops to fail if creating the dir fails
          ];
          requires = [
            "${benacofsLuksKeyName}-key.service"
          ];
          after = [
            "${benacofsLuksKeyName}-key.service"
          ];
          script =
            let
              forOsdsScript = f:
                lib.concatStringsSep
                  "\n"
                  (lib.mapAttrsToList
                    (osdIdStr: { uuid, blockDev, dbDev, ... }:
                      let
                        decryptedNameBlockDev = decryptedNameForDevice blockDev;
                        decryptedNameDbDev = decryptedNameForDevice dbDev;
                      in
                        f { inherit osdIdStr uuid blockDev dbDev decryptedNameBlockDev decryptedNameDbDev; }
                    )
                    cephOSDs
                  );
            in
              ''
                set -euo pipefail

                # If the machine was newly created, encrypt the disks. Wipes their data!
                # Do it in parallel (see & at the end of each `cryptsetup` invocation)
                ${forOsdsScript ({ osdIdStr, uuid, blockDev, dbDev, decryptedNameBlockDev, decryptedNameDbDev }:
                  let
                    osdInitialEncryptionDoneDir = "/var/lib/ceph-osd-encryption";
                    osdInitialEncryptionDoneFile = "${osdInitialEncryptionDoneDir}/.${osdIdStr}.${uuid}.nix-existence";
                  in
                    ''
                      if ! [ -e "${osdInitialEncryptionDoneFile}" ]; then
                        echo "Running luksFormat for osd.${osdIdStr} with UUID ${uuid}, effectively wiping any previous data!"
                        ${pkgs.cryptsetup}/bin/cryptsetup --batch-mode luksFormat --type luks2 "${blockDev}" --key-file "${config.deployment.keys.${benacofsLuksKeyName}.path}" &
                        ${pkgs.cryptsetup}/bin/cryptsetup --batch-mode luksFormat --type luks2 "${dbDev}"    --key-file "${config.deployment.keys.${benacofsLuksKeyName}.path}" &
                      fi
                      mkdir -p "${osdInitialEncryptionDoneDir}"
                      touch "${osdInitialEncryptionDoneFile}"
                    ''
                )}

                # TODO: This `wait` discards exit codes!
                #       It's acceptable for now because the next commands will fail then.
                #       Rewrite this script in Python to keep it parallel.
                #       See: #1538#issuecomment-779934307
                wait # for the parallel jobs (see above)

                # Open in parallel (see & at the end of each `cryptsetup` invocation)
                ${forOsdsScript ({ osdIdStr, uuid, blockDev, dbDev, decryptedNameBlockDev, decryptedNameDbDev }: ''
                  if ! [ -e "/dev/mapper/${decryptedNameBlockDev}" ]; then
                    echo "Running luksOpen for osd.${osdIdStr} with UUID ${uuid}"
                    ${pkgs.cryptsetup}/bin/cryptsetup luksOpen "${blockDev}" "${decryptedNameBlockDev}" --key-file "${config.deployment.keys.${benacofsLuksKeyName}.path}" &
                  fi
                  if ! [ -e "/dev/mapper/${decryptedNameDbDev}" ]; then
                    echo "Running luksOpen for osd.${osdIdStr} BlueStore DB with UUID ${uuid}"
                    ${pkgs.cryptsetup}/bin/cryptsetup luksOpen "${dbDev}" "${decryptedNameDbDev}" --key-file "${config.deployment.keys.${benacofsLuksKeyName}.path}" &
                  fi
                '')}

                # TODO: This `wait` discards exit codes!
                #       It's acceptable for now because the next commands will fail then.
                #       Rewrite this script in Python to keep it parallel.
                #       See: #1538#issuecomment-779934307
                wait # for the parallel jobs (see above)

                # Wait for osdIdStr, uuid,  devices to appear
                ${forOsdsScript ({ osdIdStr, uuid, blockDev, dbDev, decryptedNameBlockDev, decryptedNameDbDev }: ''
                  echo "Running udevadm settle for osd.${osdIdStr} with UUID ${uuid}"
                  ${pkgs.systemd}/bin/udevadm settle --timeout=60 --exit-if-exists="/dev/mapper/${decryptedNameBlockDev}"
                  echo "Running udevadm settle for osd.${osdIdStr} BlueStore DB with UUID ${uuid}"
                  ${pkgs.systemd}/bin/udevadm settle --timeout=60 --exit-if-exists="/dev/mapper/${decryptedNameDbDev}"
                '')}
              '';
          serviceConfig = {
            Type = "oneshot";
          };
        };

        # ceph

        services.benaco-ceph-server = {
          enable = true;
          nodeName = netInfo.hostName;
          initialMonitorKeyring = ./. + "/${secretsDirName}/ceph/ceph.mon.keyring";
        };

        services.ceph-benaco = cephCommonConfig // (
          let
            mkOsd = osdIdInt: { blockDev, dbDev, uuid }: {
              enable = true;
              bootstrapKeyring = ./. + "/${secretsDirName}/ceph/ceph.client.bootstrap-osd.keyring";
              id = osdIdInt;
              inherit uuid;
              systemdExtraRequiresAfter = [
                (serviceUnitOf config.systemd.services.benacofs-luks-format-or-open-osds)
              ];
              # ceph-volume cannot zap device-mapper devices (https://tracker.ceph.com/issues/24504)
              # and `luksFormat` zaps it anyway.
              skipZap = true;
              blockDevice = "/dev/mapper/${decryptedNameForDevice blockDev}";
              blockDeviceUdevRuleMatcher = ''ENV{DM_NAME}=="${decryptedNameForDevice blockDev}"'';
              dbBlockDevice = "/dev/mapper/${decryptedNameForDevice dbDev}";
              dbBlockDeviceUdevRuleMatcher = ''ENV{DM_NAME}=="${decryptedNameForDevice dbDev}"'';
            };
          in
            {
              osds = lib.mapAttrs (osdIdStr: value: mkOsd (lib.toInt osdIdStr) value) cephOSDs;
            }
        );

        services.benaco-ceph-client = {
          enable = true;
          doBenacofsSetup = netInfo.hostName == "corpfs-1";
          initialNumPlacementGroups = 256;
          benacofsWatchdogAddress = netInfo.hostName;
          benacofsMountPath = benacofs_files_dir;
          # Not using FUSE here because on single-node local ceph we measured
          # 80 MB/s with FUSE and 3200 MB/s with the kernel mount, using:
          #     dd if=/dev/zero bs=100M of=/shared/corp/root/testfile status=progress
          fuse = false;
        };

      };
  };

  # Example:
  #   serviceUnitOf cfg.systemd.services.myservice == "myservice.service"
  serviceUnitOf = service: "${service._module.args.name}.service";

  corpfsMachines = if deployToAws then [] else [ # We haven't set up corpfs on AWS yet
    # UUIDs generated with `uuidgen`
    (mkCorpfsNode {
      i = 1;
      physicalSpecModule = mkHetznerSX133_10x16TB_with2x960GBssds_physicalSpecModule { ip = "157.90.48.50"; robotSubAccount = "#1374951+5LaTb"; };
      cephOSDs = {
        "0"  = { blockDev = "/dev/disk/by-partlabel/OSD-data-partition-a"; dbDev = "/dev/disk/by-partlabel/BlueStore-DB-partition-a"; uuid = "a9bbeb2e-1149-4390-bd36-02caf8e2df09"; };
        "1"  = { blockDev = "/dev/disk/by-partlabel/OSD-data-partition-b"; dbDev = "/dev/disk/by-partlabel/BlueStore-DB-partition-b"; uuid = "f31cf5ee-88d1-41d3-9b5b-4677dc6e45d4"; };
        "2"  = { blockDev = "/dev/disk/by-partlabel/OSD-data-partition-c"; dbDev = "/dev/disk/by-partlabel/BlueStore-DB-partition-c"; uuid = "75dd903a-6636-4ba7-a7fa-ac81df3726bc"; };
        "3"  = { blockDev = "/dev/disk/by-partlabel/OSD-data-partition-d"; dbDev = "/dev/disk/by-partlabel/BlueStore-DB-partition-d"; uuid = "9d647f56-c0f6-43ef-948f-f7786a87b1cf"; };
        "4"  = { blockDev = "/dev/disk/by-partlabel/OSD-data-partition-e"; dbDev = "/dev/disk/by-partlabel/BlueStore-DB-partition-e"; uuid = "0fcc41c8-3b3b-4f0a-b9ec-befe33a922df"; };
        "5"  = { blockDev = "/dev/disk/by-partlabel/OSD-data-partition-f"; dbDev = "/dev/disk/by-partlabel/BlueStore-DB-partition-f"; uuid = "1689ab62-0d99-4da8-961e-f8f9ce533408"; };
        "6"  = { blockDev = "/dev/disk/by-partlabel/OSD-data-partition-g"; dbDev = "/dev/disk/by-partlabel/BlueStore-DB-partition-g"; uuid = "9c6a96a6-83d7-40fa-bb4e-7e22545cdc80"; };
        "7"  = { blockDev = "/dev/disk/by-partlabel/OSD-data-partition-h"; dbDev = "/dev/disk/by-partlabel/BlueStore-DB-partition-h"; uuid = "97243a04-b1f8-4f67-9e10-509530a8a94a"; };
        "8"  = { blockDev = "/dev/disk/by-partlabel/OSD-data-partition-i"; dbDev = "/dev/disk/by-partlabel/BlueStore-DB-partition-i"; uuid = "7052cfd1-090c-43d5-abbf-9f2aec211bcc"; };
        "9"  = { blockDev = "/dev/disk/by-partlabel/OSD-data-partition-j"; dbDev = "/dev/disk/by-partlabel/BlueStore-DB-partition-j"; uuid = "26ed3fa6-35b4-44c8-acb8-a4d7545c80c5"; };
      };
    })
    # TODO: After adding more corpfs nodes:
    #       Currently we only have 1 corpfs node. So we set:
    #           ceph osd pool set benacofs_data size 1 # via `osd pool default size = 1
    #           ceph osd pool set benacofs_metadata size 1 # via `osd pool default size = 1
    #           ceph osd pool set benacofs_data pg_num 256 # via `initialNumPlacementGroups = 256;`
    #           ceph osd pool set benacofs_data pgp_num 256 # via `initialNumPlacementGroups = 256;`
    #           ceph osd pool set benacofs_metadata pg_num 256  # via `initialNumPlacementGroups = 256;`
    #           ceph osd pool set benacofs_metadata pgp_num 256  # via `initialNumPlacementGroups = 256;`
    #       You can see the status in
    #           ceph osd pool ls detail
    #       We subsequently also changed to single-node RAID1 mode as described in
    #       https://linoxide.com/linux-how-to/hwto-configure-single-node-ceph-cluster/,
    #       changing the CRUSH map from
    #           step chooseleaf firstn 0 type host
    #       to:
    #           step chooseleaf firstn 0 type osd
    #       and then running:
    #           ceph osd pool set benacofs_data size 2
    #           ceph osd pool set benacofs_data min_size 2
    #           ceph osd pool set benacofs_metadata size 2
    #           ceph osd pool set benacofs_metadata min_size 2
    #
    #       After we add nodes 2 and 3, you need to first undo the changes described in
    #       https://linoxide.com/linux-how-to/hwto-configure-single-node-ceph-cluster/,
    #       changing CRUSH from `osd` back to `host`, and then run:
    #           ceph osd pool set benacofs_data size 3
    #           ceph osd pool set benacofs_data min_size 2
    #           ceph osd pool set benacofs_metadata size 3
    #           ceph osd pool set benacofs_metadata min_size 2
    #           ceph osd pool set benacofs_data pg_num 1024
    #           ceph osd pool set benacofs_data pgp_num 1024
    #           ceph osd pool set benacofs_metadata pg_num 1024
    #           ceph osd pool set benacofs_metadata pgp_num 1024
    #       And remove from `extraConfig` above the line:
    #           osd pool default size = 1
    #       See https://docs.ceph.com/en/latest/rados/operations/pools/?#set-the-number-of-object-replicas
    #       and https://ceph.io/rados/new-in-nautilus-pg-merging-and-autotuning/
    #       and https://ceph.io/pgcalc/.
  ];

  machines = corpfsMachines;

  allVpnNodes = map ({ netInfo, ... }: {
    inherit netInfo;
  }) machines;

in
{
  network.enableRollback = true;

  defaults = defaultMachineConfigModule;

  resources.ec2SecurityGroups =
    builtins.listToAttrs
      (map
        (region: {
          name = securityGroupResourceNameForRegion region;
          value = makeSecurityGroup { inherit region; };
        })
        (builtins.attrNames ec2RegionsUsed)
      );

} // # Add an entry in the network for each machine.
  builtins.listToAttrs (map ({ netInfo, nodeConfig, ... }: { name = netInfo.hostName; value = nodeConfig; }) machines)
