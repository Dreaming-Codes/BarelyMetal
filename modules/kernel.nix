{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.barelyMetal.kernel;
  mainCfg = config.barelyMetal;
in
{
  options.barelyMetal.kernel = {
    enable = lib.mkEnableOption "BarelyMetal CachyOS kernel with anti-detection patches";

    svmPatch = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Apply the AutoVirt SVM/RDTSC kernel patch.
        This mitigates timing-based VM detection via RDTSC.
      '';
    };

    extraPatches = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = "Additional kernel patches to apply on top of CachyOS + SVM patch.";
    };

    variant = lib.mkOption {
      type = lib.types.str;
      default = "linux-cachyos-bore";
      description = ''
        CachyOS kernel variant to use as base. Must match an attribute in
        pkgs.cachyosKernels (provided by nix-cachyos-kernel overlay).
        Common choices: linux-cachyos-bore, linux-cachyos-latest, linux-cachyos-eevdf.
      '';
    };

    processorOpt = lib.mkOption {
      type = lib.types.enum [
        "x86_64-v1"
        "x86_64-v2"
        "x86_64-v3"
        "x86_64-v4"
        "zen4"
        "native"
      ];
      default = "x86_64-v1";
      description = "CPU micro-architecture optimization level.";
    };

    hzTicks = lib.mkOption {
      type = lib.types.enum [
        "100"
        "250"
        "300"
        "500"
        "600"
        "750"
        "1000"
      ];
      default = "1000";
      description = "Kernel timer frequency.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs ? cachyosKernels;
        message = ''
          barelyMetal.kernel requires the nix-cachyos-kernel overlay.
          Add to your flake inputs:
            nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
          Then apply the overlay:
            nixpkgs.overlays = [ nix-cachyos-kernel.overlays.pinned ];
        '';
      }
    ];

    boot.kernelPackages =
      let
        baseKernel = pkgs.cachyosKernels.${cfg.variant} or (throw "Unknown CachyOS variant: ${cfg.variant}");

        svmPatchFile = "${mainCfg._internal.autovirtSrc}/patches/Kernel/linux-6.18.8-svm.patch";

        patches =
          lib.optional cfg.svmPatch svmPatchFile
          ++ cfg.extraPatches;

        customKernel = baseKernel.override {
          inherit patches;
          processorOpt = cfg.processorOpt;
          hzTicks = cfg.hzTicks;
          cpusched = "bore";
          tickrate = "full";
          preemptType = "full";
          ccHarder = true;
        };
      in
      pkgs.linuxKernel.packagesFor customKernel;
  };
}
