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
    enable = lib.mkEnableOption "BarelyMetal kernel anti-detection patches";

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
      description = "Additional kernel patches to apply.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelPatches =
      let
        svmPatchFile = "${mainCfg._internal.autovirtSrc}/patches/Kernel/linux-6.18.8-svm.patch";
      in
      lib.optional cfg.svmPatch {
        name = "barely-metal-svm-antidetection";
        patch = svmPatchFile;
      }
      ++ map (p: { name = "barely-metal-extra-${baseNameOf (toString p)}"; patch = p; }) cfg.extraPatches;

    # Required by the SVM anti-detection patch
    boot.kernelParams = [
      "mitigations=off"
      "idle=poll"
      "processor.max_cstate=1"
      "tsc=reliable"
    ];
  };
}
