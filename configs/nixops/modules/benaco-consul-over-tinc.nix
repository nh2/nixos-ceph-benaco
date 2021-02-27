{ config, pkgs, ... }:

with pkgs.lib;

let
  cfg = config.services.benaco-consul-over-tinc;

  consul-scripting-helper = import ../consul-scripting-helper.nix { inherit pkgs; };
  consul-scripting-helper-exe = "${consul-scripting-helper}/bin/consul-scripting-helper";

  # Settings for both servers and agents
  webUi = true;
  retry_interval = "1s";
  raft_multiplier = 1;

  # Example:
  #   serviceUnitOf cfg.systemd.services.myservice == "myservice.service"
  serviceUnitOf = service: "${service._module.args.name}.service";

in {

  imports = [
    ./benaco-consul-ready.nix
  ];

  options = {

    services.benaco-consul-over-tinc = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          To enable the Benaco customized Consul service.
          Includes:
          * A consul server or agent service running inside Tinc VPN
          * the `systemd.services.consulReady` service to wait for consul being up
        '';
      };

      isServer = mkOption {
        type = types.bool;
        default = false;
        description = ''Whether to start a consul server instead of an agent.'';
      };

      allConsensusServerHosts = mkOption {
        type = types.listOf types.str;
        description = ''
          Addresses or IPs of all consensus servers in the Consul cluster.
          Its length should be at least 3 to tolerate the failure of 1 node
          (though less than that will work for testing).
          Used in Consul's `bootstrap-expect` setting.
        '';
        example = ["10.0.0.1" "10.0.0.2" "10.0.0.3"];
      };

      thisConsensusServerHost = mkOption {
        type = types.str;
        description = ''
          Address or IP of this consensus server.
          Should be an element of the `allConsensusServerHosts` lists.
          Used to work around https://github.com/hashicorp/consul/issues/2868.
        '';
        example = "10.0.0.1";
      };

      unsafeUseEphemeralDataDir = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to place the consul data dir on /tmp (assumed to be a tmpfs).
          This is NOT safe to use in production.

          This is to reduce fdatasync() load for the case we don't care about
          persistence (e.g. for container-based CI).
          It removes a lot of grey in htop and HD seeks on spinning disks.

          It also means that consul state will be completely lost by rebooting.
          Don't use it if you want consul to work across reboots.
        '';
        # Note: A better solution to work across orderly reboots would be to
        # put the data dir on a partition that's mounted `nobarrier`,
        # but we haven't found a way to mount image files inside a container yet.
      };

      probeIntervalMs = mkOption {
        type = types.int;
        default = 1000;
        description = ''
          Sets Consul's gossip_lan.probe_interval setting to the given
          number of milliseconds.
        '';
      };

    };

  };

  config = {

    services.benaco-consul-ready = {
      enable = cfg.enable;
    };


    services.consul =
      let
        # Set reconnect timeout (after which unreachable nodes are removed from
        # the cluster) very high. The default is 72 hours. We don't nodes
        # removed after this time, because then the system cannot recover
        # by itself after this long an outage (this can happen if a single
        # machine fails for multiple days, e.g. when
        # https://github.com/gsliepen/tinc/issues/218 happens).
        reconnect_timeout_hours = 24 * 365; # 1 year
        defaultExtraConfig = {
          bind_addr = config.services.benaco-tinc.vpnIPAddress;
          inherit retry_interval;
          performance = {
            inherit raft_multiplier;
          };
          reconnect_timeout = "${toString reconnect_timeout_hours}h";
          reconnect_timeout_wan = "${toString reconnect_timeout_hours}h";
          # We want check outputs to be reflected immediately.
          # Unfortunately due to https://github.com/hashicorp/consul/issues/1057,
          # "0s" doesn't actually work, so we use "1ns" instead.
          check_update_interval = "1ns";
          dns_config = {
            # TODO Check if this is really necessary.
            # I found that the consul DNS API returned no results
            # for a service even when the HTTP API gave results
            # just before. This option seems to help.
            allow_stale = false;
          };
          # Enable script checks
          enable_script_checks = true;
          # Enable `/debug` endpoint to be able to get goroutine stacktraces
          # when Consul gets stuck.
          # See https://github.com/hashicorp/consul/issues/3700
          # and https://github.com/sorintlab/stolon/issues/397.
          enable_debug = true;

          gossip_lan = {
            # Despite being named "interval", this actually controls a timeout:
            # https://github.com/hashicorp/memberlist/issues/175
            probe_interval = "${toString cfg.probeIntervalMs}ms";
          };

          # This assumes `/tmp` is mounted as tmpfs.
        } // (if cfg.unsafeUseEphemeralDataDir then { data_dir = "/tmp/consul-data-dir"; } else {});

        numConsensusServers = builtins.length cfg.allConsensusServerHosts;
      in
      if cfg.isServer
        then
          assert builtins.elem cfg.thisConsensusServerHost cfg.allConsensusServerHosts;
          {
            enable = cfg.enable;
            inherit webUi;
            extraConfig = defaultExtraConfig // {
              server = true;
              bootstrap_expect = numConsensusServers;
              # Tell Consul that we never intend to drop below this many servers.
              # Ensures to not permanently lose consensus after temporary loss.
              # See https://github.com/hashicorp/consul/issues/8118#issuecomment-645330040
              autopilot.min_quorum = numConsensusServers;
              retry_join =
                # If there's only 1 node in the network, we allow self-join;
                # otherwise, the node must not try to join itself, and join only the other servers.
                # See https://github.com/hashicorp/consul/issues/2868
                if numConsensusServers == 1
                  then cfg.allConsensusServerHosts
                  else builtins.filter (h: h != cfg.thisConsensusServerHost) cfg.allConsensusServerHosts;
            };
          }
        else
          {
            enable = cfg.enable;
            inherit webUi;
            extraConfig = defaultExtraConfig // {
              server = false;
              retry_join = cfg.allConsensusServerHosts;
            };
          };


    # Helper systemd service to ensure consul starts after tinc.
    # See README note "Design of the `*after*` services"
    systemd.services.consulAfterTinc = mkIf cfg.enable {
      requiredBy = [ (serviceUnitOf config.systemd.services.consul) ];
      before = [ (serviceUnitOf config.systemd.services.consul) ];
      # Ideally we would wait for the virtual device, as opposed to "tinc.${vpnNetworkName}.service",
      # to ensure that we can actually bind to the interface
      # (otherwise we may get `bind: cannot assign requested address`).
      # But we couldn't find a systemd target that ensures that device is actually ready.
      # So instead, we've made tinc signal to systemd when the connection is up,
      # using `systemd-notify` in "preStart". As a result we can now safely wait for
      # "tinc.${vpnNetworkName}.service".
      bindsTo = [ (serviceUnitOf config.systemd.services."tinc.${config.services.benaco-tinc.vpnNetworkName}")  ];
      after = [ (serviceUnitOf config.systemd.services."tinc.${config.services.benaco-tinc.vpnNetworkName}")  ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        Restart = "always";
      };
      unitConfig = {
        StartLimitIntervalSec = 0; # ensure Restart=always is always honoured
      };
    };

  };

}
