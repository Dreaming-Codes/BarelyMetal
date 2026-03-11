{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.barelyMetal.vfio;
  mainCfg = config.barelyMetal;
  facterLib = import ../lib/facter.nix { inherit lib; };

  hasFacter = (config.hardware.facter.reportPath or null) != null;
  facterReport = if hasFacter then config.hardware.facter.report else { };

  probe = mainCfg.probeData;
  hasProbe = probe != { };

  resolvedCpu = facterLib.firstNonNull [
    mainCfg.cpu
    (facterLib.getCpuFromProbe probe)
    (if hasFacter then facterLib.detectCpuFromFacter facterReport else null)
  ] "amd";
in
{
  options.barelyMetal.vfio = {
    enable = lib.mkEnableOption "VFIO GPU passthrough configuration";

    pciIds = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "10de:2484"
        "10de:228b"
      ];
      description = ''
        PCI vendor:device ID pairs to bind to vfio-pci.
        Use `lspci -nn` to find your GPU's IDs.
        Include both the GPU and its audio device.
      '';
    };

    blacklistDrivers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "nvidia"
        "nouveau"
      ];
      description = ''
        GPU drivers to blacklist so vfio-pci can claim the device.
        When using nix-facter, drivers are auto-detected from the report
        for devices matching pciIds (if this list is left empty).
      '';
    };

    autoDetectDrivers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Auto-detect and blacklist GPU drivers from nix-facter for
        devices matching pciIds. Requires hardware.facter.reportPath.
      '';
    };

    enableIommu = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Add IOMMU kernel parameters automatically.";
    };

    acsOverride = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable ACS Override patch (requires patched kernel).
        Use with caution — reduces IOMMU isolation guarantees.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.pciIds != [ ];
        message = "barelyMetal.vfio.pciIds must contain at least one PCI ID when VFIO is enabled.";
      }
    ];

    boot = {
      kernelModules = [
        "vfio"
        "vfio_iommu_type1"
        "vfio_pci"
      ];

      kernelParams =
        let
          isIntel = resolvedCpu == "intel";
        in
        lib.optionals cfg.enableIommu (
          [ "iommu=pt" ]
          ++ lib.optional isIntel "intel_iommu=on"
        )
        ++ lib.optional cfg.acsOverride "pcie_acs_override=downstream,multifunction"
        ++ [ "vfio-pci.ids=${lib.concatStringsSep "," cfg.pciIds}" ];

      extraModprobeConfig =
        let
          detectedDrivers =
            if cfg.blacklistDrivers != [ ] then
              cfg.blacklistDrivers
            else if hasFacter && cfg.autoDetectDrivers then
              let
                allGpus = facterReport.hardware.graphics_card or [ ];
                matchingGpus = builtins.filter (
                  gpu:
                  builtins.elem "${gpu.vendor.hex or ""}:${gpu.device.hex or ""}" cfg.pciIds
                ) allGpus;
              in
              lib.unique (lib.concatMap (gpu: gpu.driver_modules or [ ]) matchingGpus)
            else
              [ ];

          softdepLines = map (drv: "softdep ${drv} pre: vfio-pci") detectedDrivers;
        in
        lib.concatStringsSep "\n" (
          [ "options vfio-pci ids=${lib.concatStringsSep "," cfg.pciIds}" ]
          ++ softdepLines
        );

      blacklistedKernelModules =
        if cfg.blacklistDrivers != [ ] then
          cfg.blacklistDrivers
        else if hasFacter && cfg.autoDetectDrivers then
          let
            allGpus = facterReport.hardware.graphics_card or [ ];
            matchingGpus = builtins.filter (
              gpu:
              builtins.elem "${gpu.vendor.hex or ""}:${gpu.device.hex or ""}" cfg.pciIds
            ) allGpus;
          in
          lib.unique (lib.concatMap (gpu: gpu.driver_modules or [ ]) matchingGpus)
        else
          [ ];
    };
  };
}
