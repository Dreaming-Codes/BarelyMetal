{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.barelyMetal.lookingGlass;
  mainCfg = config.barelyMetal;

  facterLib = import ../lib/facter.nix { inherit lib; };
  probe = mainCfg.probeData or { };
  hasFacter = (config.hardware.facter.reportPath or null) != null;
  facterReport = if hasFacter then config.hardware.facter.report else { };

  resolvedCpu = facterLib.firstNonNull [
    (mainCfg.cpu or null)
    (facterLib.getCpuFromProbe probe)
    (if hasFacter then facterLib.detectCpuFromFacter facterReport else null)
  ] "amd";

  spoofedVendorId =
    if resolvedCpu == "intel" then "0x8086" else "0x1022";
  spoofedDeviceId =
    if resolvedCpu == "intel" then "0x0E20" else "0x1440";

  kvmfrModule = pkgs.linuxPackages.callPackage ../pkgs/kvmfr {
    inherit spoofedVendorId spoofedDeviceId;
  };
in
{
  options.barelyMetal.lookingGlass = {
    enable = lib.mkEnableOption "Looking Glass (low-latency KVMFR display)";

    shmSize = lib.mkOption {
      type = lib.types.int;
      default = 32;
      description = "Shared memory size in MiB for the KVMFR device.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "User that owns /dev/shm/looking-glass.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "kvm";
      description = "Group that owns /dev/shm/looking-glass.";
    };

    spoofKvmfrIds = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Patch the KVMFR kernel module to use spoofed PCI vendor/device IDs
        instead of the default Red Hat VirtIO IDs (0x1af4/0x1110) which
        are easily detected as virtual hardware.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.looking-glass-client ];

    systemd.tmpfiles.rules = [
      "f /dev/shm/looking-glass 0660 ${cfg.user} ${cfg.group} -"
    ];

    boot.extraModprobeConfig = ''
      options kvmfr static_size_mb=${toString cfg.shmSize}
    '';

    boot.kernelModules = [ "kvmfr" ];

    # TODO: Build patched kvmfr module when spoofKvmfrIds is true
    # For now this requires the user to have kvmfr in their kernel or extraModulePackages
  };
}
