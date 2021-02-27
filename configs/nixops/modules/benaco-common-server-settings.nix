{ config, pkgs, lib, ... }:

with pkgs.lib;

let
  cfg = config.benaco-server-settings;
in
{

  imports = [
  ];

  options = {
  };

  config = {

    # TODO: Remove when https://github.com/NixOS/nixpkgs/pull/85119 is available to us.
    boot.kernelPatches = [
      # Needed by `dropwatch` to observe dropped packages.
      {
        name = "dropwatch";
        patch = null;
        extraConfig = ''
          NET_DROP_MONITOR y
        '';
      }
    ];

    # Enable BBR congestion control
    boot.kernelModules = [ "tcp_bbr" ];
    boot.kernel.sysctl."net.ipv4.tcp_congestion_control" = "bbr";
    boot.kernel.sysctl."net.core.default_qdisc" = "fq"; # see https://news.ycombinator.com/item?id=14814530

    # Increase TCP window sizes for high-bandwidth WAN connections, assuming
    # 10 GBit/s Internet over 200ms latency as worst case.
    #
    # Choice of value:
    #     BPP         = 10000 MBit/s / 8 Bit/Byte * 0.2 s = 250 MB
    #     Buffer size = BPP * 4 (for BBR)                 = 1 GB
    # Explanation:
    # * According to http://ce.sc.edu/cyberinfra/workshops/Material/NTP/Lab%208.pdf
    #   and other sources, "Linux assumes that half of the send/receive TCP buffers
    #   are used for internal structures", so the "administrator must configure
    #   the buffer size equals to twice" (2x) the BPP.
    # * The article's section 1.3 explains that with moderate to high packet loss
    #   while using BBR congestion control, the factor to choose is 4x.
    #
    # Note that the `tcp` options override the `core` options unless `SO_RCVBUF`
    # is set manually, see:
    # * https://stackoverflow.com/questions/31546835/tcp-receiving-window-size-higher-than-net-core-rmem-max
    # * https://bugzilla.kernel.org/show_bug.cgi?id=209327
    # There is an unanswered question in there about what happens if the `core`
    # option is larger than the `tcp` option; to avoid uncertainty, we set them
    # equally.
    boot.kernel.sysctl."net.core.wmem_max" = "1073741824"; # 1 GiB
    boot.kernel.sysctl."net.core.rmem_max" = "1073741824"; # 1 GiB
    boot.kernel.sysctl."net.ipv4.tcp_rmem" = "4096 87380 1073741824"; # 1 GiB max
    boot.kernel.sysctl."net.ipv4.tcp_wmem" = "4096 87380 1073741824"; # 1 GiB max
    # We do not need to adjust `net.ipv4.tcp_mem` (which limits the total
    # system-wide amount of memory to use for TCP, counted in pages) because
    # the kernel sets that to a high default of ~9% of system memory, see:
    # * https://github.com/torvalds/linux/blob/a1d21081a60dfb7fddf4a38b66d9cef603b317a9/net/ipv4/tcp.c#L4116

    # mdadm needs an email address, see https://github.com/NixOS/nixpkgs/issues/72394
    # We use `root` for now until we have tested whether our machines
    # can send emails.
    environment.etc."mdadm.conf".text = ''
      MAILADDR root
    '';

    # Accept LetsEncrypt terms.
    security.acme = {
      acceptTerms = true;
      email = "services+letsencrypt@benaco.com";
    };

    # TODO Remove when we're on a NixOS version that has https://github.com/systemd/systemd/pull/13754
    #      available.
    systemd.package = pkgs.patched_systemd; # from overlay

    # Increase journald logging rate limit.
    # This is to avoid journald swalloing important investigation messages.
    services.journald.rateLimitBurst = 10000; # default is 1000
    services.journald.rateLimitInterval = "30s"; # the default; just for clarity

    # Stop systemd from cleaning /tmp files/dirs older than 10 days
    # without constraints, restricting it to that check at boot only.
    # The added `!` adds the boot-only, see `man tmpfiles.d` and #1249.
    # systemd's default of `q /tmp 1777 root root 10d`, see
    #     https://github.com/systemd/systemd/blob/db1442260a56963a8aa507787e71b97e5f08f17c/tmpfiles.d/tmp.conf#L10-L12
    # is not good because services like `benaco-worker` do not expect that the
    # temp dirs they created disappear on them.
    #
    # The run of `systemd-tmpfiles` can be checked with verbosity like so (from
    # https://unix.stackexchange.com/questions/438471/when-are-files-from-tmp-deleted):
    #
    #     SYSTEMD_LOG_LEVEL=debug systemd-tmpfiles --clean
    #
    # Note that as of writing, that command has some weird (and apparently
    # undocumented) pipe special case logic, so you cannot e.g. `grep` it.
    #
    # Note thet using `systemd.tmpfiles.rules` here did not work, instead
    # we have to override the upstream file, see
    #
    # * https://github.com/NixOS/nixpkgs/issues/86600
    # * https://github.com/systemd/systemd/issues/15675
    # * #1249#issuecomment-622965217
    environment.etc."tmpfiles.d/tmp.conf".source =
      lib.mkForce (pkgs.runCommand "tmp-clean-only-on-boot.conf" {} ''
        cp "${pkgs.systemd}/example/tmpfiles.d/tmp.conf" "$out"

        exit=0
        grep 'q /tmp ' "$out" || exit=$?
        if [ $exit -ne 0 ]; then
          >&2 echo "Systemd upstream 'tmpfiles.d/tmp.conf' changed, review override!"
          exit 1
        fi

        substituteInPlace "$out" --replace "q /tmp " "# OVERRIDDEN to clean /tmp only on boot!
        q! /tmp "
      '');

    # zsh
    programs.zsh.enable = true;
    programs.zsh.interactiveShellInit = ''
      source ${pkgs.grml-zsh-config}/etc/zsh/zshrc

      alias d='ls -lah'
      alias g=git
    '';
    programs.zsh.promptInit = ""; # otherwise it'll override the grml prompt

    users.users.root.shell = pkgs.zsh;

  };

}
