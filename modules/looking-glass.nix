{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.barelyMetal.lookingGlass;
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
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.looking-glass-client ];

    systemd.tmpfiles.rules = [
      "f /dev/shm/looking-glass 0660 ${cfg.user} ${cfg.group} -"
    ];

    boot.extraModprobeConfig = ''
      options kvmfr static_size_mb=${toString cfg.shmSize}
    '';
  };
}
