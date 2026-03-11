{
  self,
  autovirt,
  qemu-src,
  edk2-src,
}:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.barelyMetal;
  vmCfg = cfg.vm;
  spoofCfg = cfg.spoofing;

  facterLib = import ../lib/facter.nix { inherit lib; };
  inherit (facterLib) firstNonNull;

  hasFacter = (config.hardware.facter.reportPath or null) != null;
  facterReport = if hasFacter then config.hardware.facter.report else { };

  probe = cfg.probeData;
  hasProbe = probe != { };

  # --- Unified resolution: manual override > probe > facter > default ---

  resolvedCpu = firstNonNull [
    cfg.cpu
    (facterLib.getCpuFromProbe probe)
    (if hasFacter then facterLib.detectCpuFromFacter facterReport else null)
  ] "amd";

  resolvedBiosVendor = firstNonNull [
    spoofCfg.biosVendor
    (facterLib.getBiosVendorFromProbe probe)
    (if hasFacter then facterLib.getBiosVendorFromFacter facterReport else null)
  ] "American Megatrends International, LLC.";

  resolvedBiosVersion = firstNonNull [
    spoofCfg.biosVersion
    (facterLib.getBiosVersionFromProbe probe)
    (if hasFacter then facterLib.getBiosVersionFromFacter facterReport else null)
  ] "1.0";

  resolvedBiosDate = firstNonNull [
    spoofCfg.biosDate
    (facterLib.getBiosDateFromProbe probe)
    (if hasFacter then facterLib.getBiosDateFromFacter facterReport else null)
  ] "01/01/2024";

  resolvedBiosRevision = firstNonNull [
    spoofCfg.biosRevision
    (facterLib.getBiosRevisionFromProbe probe)
  ] "0x00010000";

  resolvedSmbiosManufacturer = firstNonNull [
    spoofCfg.smbiosManufacturer
    (facterLib.getProcessorManufacturerFromProbe probe)
    (if hasFacter then facterLib.getProcessorManufacturerFromFacter facterReport else null)
  ] (if resolvedCpu == "intel" then "Intel(R) Corporation" else "Advanced Micro Devices, Inc.");

  resolvedAcpiOemId = firstNonNull [
    spoofCfg.acpiOemId
    (facterLib.getAcpiOemIdFromProbe probe)
  ] "ALASKA";

  resolvedAcpiOemTableId = firstNonNull [
    spoofCfg.acpiOemTableId
    (facterLib.getAcpiOemTableIdFromProbe probe)
  ] "A M I   ";

  resolvedAcpiOemTableIdHex = firstNonNull [
    spoofCfg.acpiOemTableIdHex
    (facterLib.getAcpiOemTableIdHexFromProbe probe)
  ] "0x20202020324B4445";

  resolvedAcpiOemRevision = firstNonNull [
    spoofCfg.acpiOemRevision
    (facterLib.getAcpiOemRevisionFromProbe probe)
  ] "0x00000002";

  resolvedAcpiCreatorId = firstNonNull [
    spoofCfg.acpiCreatorId
    (facterLib.getAcpiCreatorIdFromProbe probe)
  ] "ACPI";

  resolvedAcpiCreatorIdHex = firstNonNull [
    spoofCfg.acpiCreatorIdHex
    (facterLib.getAcpiCreatorIdHexFromProbe probe)
  ] "0x20202020";

  resolvedAcpiCreatorRevision = firstNonNull [
    spoofCfg.acpiCreatorRevision
    (facterLib.getAcpiCreatorRevisionFromProbe probe)
  ] "0x01000013";

  resolvedAcpiPmProfile = firstNonNull [
    spoofCfg.acpiPmProfile
    (facterLib.getAcpiPmProfileFromProbe probe)
  ] 1;

  cpuLower = lib.toLower resolvedCpu;

  patchedQemu = pkgs.callPackage ../../pkgs/qemu {
    inherit autovirt qemu-src;
    cpu = resolvedCpu;
    acpiOemId = resolvedAcpiOemId;
    acpiOemTableId = resolvedAcpiOemTableId;
    acpiCreatorId = resolvedAcpiCreatorId;
    acpiPmProfile = resolvedAcpiPmProfile;
    smbiosManufacturer = resolvedSmbiosManufacturer;
    spoofModels = spoofCfg.spoofModels;
    ideModel = spoofCfg.ideModel;
    nvmeModel = spoofCfg.nvmeModel;
    cdModel = spoofCfg.cdModel;
    cfataModel = spoofCfg.cfataModel;
  };

  patchedOvmf = pkgs.callPackage ../../pkgs/ovmf {
    inherit autovirt edk2-src;
    cpu = resolvedCpu;
    biosVendor = resolvedBiosVendor;
    biosVersion = resolvedBiosVersion;
    biosDate = resolvedBiosDate;
    biosRevision = resolvedBiosRevision;
    acpiOemId = resolvedAcpiOemId;
    acpiOemTableId = resolvedAcpiOemTableIdHex;
    acpiOemRevision = resolvedAcpiOemRevision;
    acpiCreatorId = resolvedAcpiCreatorIdHex;
    acpiCreatorRevision = resolvedAcpiCreatorRevision;
  };

  smbiosSpoofer = pkgs.callPackage ../../pkgs/smbios-spoofer { inherit autovirt; };
  barelyMetalUtils = pkgs.callPackage ../../pkgs/utils { inherit autovirt; };
  barelyMetalProbe = pkgs.callPackage ../../pkgs/probe { };

  stateDir = "/var/lib/barely-metal";
in
{
  options.barelyMetal = {
    enable = lib.mkEnableOption "BarelyMetal anti-detection virtualization";

    probeData = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Hardware probe data as a Nix attrset. Generate the JSON with:
          sudo barely-metal-probe -o probe.json

        Then pass it however you like:
          barelyMetal.probeData = builtins.fromJSON (builtins.readFile ./probe.json);

        Or from sops-nix:
          barelyMetal.probeData = builtins.fromJSON config.sops.placeholder."probe";

        Or inline:
          barelyMetal.probeData = { cpu = "amd"; acpi = { oem_id = "ALASKA"; ... }; ... };

        Resolution order: manual spoofing override > probeData > nix-facter > defaults.
      '';
      example = lib.literalExpression ''
        builtins.fromJSON (builtins.readFile ./probe.json)
      '';
    };

    cpu = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "amd"
          "intel"
        ]
      );
      default = null;
      description = ''
        CPU vendor override. When null, auto-detected from probeData
        or nix-facter. Falls back to "amd".
      '';
    };

    spoofing = {
      biosVendor = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "BIOS vendor string override. Null = auto-detect.";
      };

      biosVersion = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "BIOS version string override. Null = auto-detect.";
      };

      biosDate = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "BIOS release date override. Null = auto-detect.";
      };

      biosRevision = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "BIOS revision hex override. Null = auto-detect.";
      };

      smbiosManufacturer = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "SMBIOS processor manufacturer override. Null = auto-detect.";
      };

      acpiOemId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACPI OEM ID override (6 chars). Null = auto-detect from probe.";
      };

      acpiOemTableId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACPI OEM Table ID override (8 chars, for QEMU). Null = auto-detect.";
      };

      acpiOemTableIdHex = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACPI OEM Table ID hex override (for EDK2 PCD). Null = auto-detect.";
      };

      acpiOemRevision = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACPI OEM Revision hex override. Null = auto-detect.";
      };

      acpiCreatorId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACPI Creator ID override (4 chars, for QEMU). Null = auto-detect.";
      };

      acpiCreatorIdHex = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACPI Creator ID hex override (for EDK2 PCD). Null = auto-detect.";
      };

      acpiCreatorRevision = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACPI Creator Revision hex override. Null = auto-detect.";
      };

      acpiPmProfile = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "ACPI PM Profile override (1=Desktop, 2=Mobile). Null = auto-detect.";
      };

      spoofModels = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Replace virtual device model strings with realistic consumer hardware names.";
      };

      ideModel = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Custom IDE/SATA drive model. Null = default realistic model.";
      };

      nvmeModel = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Custom NVMe controller model. Null = default realistic model.";
      };

      cdModel = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Custom CD/DVD drive model. Null = default realistic model.";
      };

      cfataModel = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Custom CF/ATA drive model. Null = default realistic model.";
      };

      generateSmbiosBin = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Generate smbios.bin from host DMI tables at system activation.
          Output: ${stateDir}/firmware/smbios.bin
        '';
      };
    };

    vm = {
      memory = lib.mkOption {
        type = lib.types.int;
        default = 16384;
        description = "VM memory in MiB.";
      };

      cores = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = "Number of CPU cores for the VM.";
      };

      threads = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "Number of threads per core.";
      };

      evdevInputs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "/dev/input/by-id/usb-Logitech_G502-event-mouse"
          "/dev/input/by-id/usb-Corsair_K70-event-kbd"
        ];
        description = "Input devices for evdev passthrough.";
      };

      evdevGrabKey = lib.mkOption {
        type = lib.types.enum [
          "ctrl-ctrl"
          "alt-alt"
          "shift-shift"
          "meta-meta"
          "scrolllock"
          "ctrl-scrolllock"
        ];
        default = "ctrl-ctrl";
        description = "Key combo to toggle evdev input grab.";
      };

      pciPassthrough = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "01:00.0" ];
        description = "PCI addresses (BDF format) to pass through via VFIO.";
      };

      audioBackend = lib.mkOption {
        type = lib.types.enum [
          "none"
          "pipewire"
          "pulseaudio"
          "alsa"
        ];
        default = "pipewire";
        description = "Audio backend for the VM.";
      };

      isoPath = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to Windows ISO for initial installation.";
      };

      diskPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Path to VM disk image.";
      };

      diskSize = lib.mkOption {
        type = lib.types.str;
        default = "64G";
        description = "VM disk size (only used when creating a new disk).";
      };

      networkMac = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Custom MAC address for the VM NIC. Null generates one at activation.";
      };

      enableHyperVPassthrough = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Hyper-V enlightenments (guest appears as Hyper-V rather than KVM).";
      };

      acpiTables = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = "Additional ACPI tables (.aml) to pass to QEMU.";
      };

      useFakeBattery = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Include the bundled fake battery ACPI SSDT.";
      };
    };

    installUtilities = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install BarelyMetal utility scripts (evdev helper, VBIOS dumper, MSR checker, probe).";
    };

    _internal = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      internal = true;
      visible = false;
      description = "Internal resolved values for other modules.";
    };
  };

  config = lib.mkIf cfg.enable {
    warnings = lib.optional (!hasProbe && !hasFacter) ''
      barelyMetal: No hardware data source configured.
      All spoofing values will use generic defaults — your VM will NOT match your host.

      Generate a probe file:
        sudo barely-metal-probe -o probe.json

      Then pass the data:
        barelyMetal.probeData = builtins.fromJSON (builtins.readFile ./probe.json);

      Or from sops-nix:
        barelyMetal.probeData = builtins.fromJSON config.sops.placeholder."barely-metal/probe";
    '';

    virtualisation.libvirtd = {
      enable = true;
      qemu = {
        package = patchedQemu;
        ovmf.packages = [ patchedOvmf ];
        swtpm.enable = true;
        verbatimConfig = ''
          user = "root"
          group = "root"
          cgroup_device_acl = [
            "/dev/null", "/dev/full", "/dev/zero",
            "/dev/random", "/dev/urandom",
            "/dev/ptmx", "/dev/kvm",
            "/dev/rtc", "/dev/hpet",
            "/dev/sev"
            ${lib.concatMapStringsSep "" (d: ",\n    \"${d}\"") vmCfg.evdevInputs}
          ]
        '';
      };
    };

    programs.virt-manager.enable = true;

    users.groups.libvirtd = { };
    users.groups.kvm = { };

    boot.kernelModules = [
      "kvm"
      (if cpuLower == "amd" then "kvm-amd" else "kvm-intel")
    ];

    boot.kernelParams = lib.optionals (cpuLower == "intel") [ "intel_iommu=on" ];

    security.polkit.enable = true;

    environment.systemPackages =
      [
        patchedQemu
        smbiosSpoofer
        barelyMetalProbe
        pkgs.swtpm
        pkgs.virt-manager
      ]
      ++ lib.optional cfg.installUtilities barelyMetalUtils;

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 root root -"
      "d ${stateDir}/firmware 0750 root root -"
    ];

    system.activationScripts.barelyMetal = lib.mkIf spoofCfg.generateSmbiosBin {
      text = ''
        mkdir -p ${stateDir}/firmware

        if [ -f /sys/firmware/dmi/tables/smbios_entry_point ] && [ -f /sys/firmware/dmi/tables/DMI ]; then
          cd ${stateDir}/firmware
          ${smbiosSpoofer}/bin/barely-metal-smbios-spoofer || echo "Warning: SMBIOS spoofer failed"
          if [ -f smbios.bin ]; then
            chmod 644 smbios.bin
          fi
        fi
      '';
    };

    barelyMetal._internal = {
      qemuPackage = patchedQemu;
      ovmfPackage = patchedOvmf;
      smbiosBinPath = "${stateDir}/firmware/smbios.bin";
      firmwareDir = "${stateDir}/firmware";
      autovirtSrc = autovirt;
      inherit resolvedCpu;
    };
  };
}
