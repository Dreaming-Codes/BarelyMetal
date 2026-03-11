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
    spoofUsbSerials = spoofCfg.spoofUsbSerials;
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
    bootLogo = spoofCfg.bootLogo;
  };

  smbiosSpoofer = pkgs.callPackage ../../pkgs/smbios-spoofer { inherit autovirt; };
  barelyMetalUtils = pkgs.callPackage ../../pkgs/utils { inherit autovirt; };
  barelyMetalProbe = pkgs.callPackage ../../pkgs/probe { };
  barelyMetalDeploy = pkgs.callPackage ../../pkgs/libvirt-xml { };
  guestScripts = pkgs.callPackage ../../pkgs/guest-scripts { inherit autovirt; };

  stateDir = "/var/lib/barely-metal";

  # Build the deploy wrapper script with all resolved values baked in
  deployWrapper = pkgs.writeShellScriptBin "barely-metal-deploy-vm" ''
    exec ${barelyMetalDeploy}/bin/barely-metal-deploy \
      --qemu "${patchedQemu}/bin/qemu-system-x86_64" \
      --ovmf-code "${patchedOvmf}/FV/OVMF_CODE.fd" \
      --ovmf-vars "${stateDir}/firmware/OVMF_VARS.fd" \
      --cpu-vendor "${resolvedCpu}" \
      --memory "${toString vmCfg.memory}" \
      --cores "${toString vmCfg.cores}" \
      --threads "${toString vmCfg.threads}" \
      --grab-toggle "${vmCfg.evdevGrabKey}" \
      --audio "${vmCfg.audioBackend}" \
      ${lib.optionalString (vmCfg.networkMac != null) "--mac \"${vmCfg.networkMac}\""} \
      ${lib.optionalString vmCfg.enableHyperVPassthrough "--hyperv"} \
      ${lib.optionalString (vmCfg.isoPath != null) "--iso \"${toString vmCfg.isoPath}\""} \
      ${lib.optionalString (vmCfg.diskPath != null) "--disk \"${vmCfg.diskPath}\" --disk-size \"${vmCfg.diskSize}\""} \
      --smbios-bin "${stateDir}/firmware/smbios.bin" \
      ${lib.concatMapStringsSep " " (t: "--acpi-table \"${toString t}\"") resolvedAcpiTables} \
      ${lib.concatMapStringsSep " " (d: "--evdev \"${d}\"") vmCfg.evdevInputs} \
      "$@"
  '';

  # Resolve ACPI tables: user-specified + bundled fake battery + bundled spoofed devices
  resolvedAcpiTables =
    vmCfg.acpiTables
    ++ lib.optional vmCfg.useFakeBattery "${guestScripts}/share/barely-metal/acpi/fake_battery.dsl"
    ++ lib.optional vmCfg.useSpoofedDevices "${guestScripts}/share/barely-metal/acpi/spoofed_devices.aml";
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

        Resolution order: manual spoofing override > probeData > nix-facter > defaults.
      '';
      example = lib.literalExpression ''builtins.fromJSON (builtins.readFile ./probe.json)'';
    };

    cpu = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "amd" "intel" ]);
      default = null;
      description = "CPU vendor override. Null = auto-detect from probeData/facter.";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "myuser" ];
      description = "Users to add to kvm, libvirtd, and input groups.";
    };

    spoofing = {
      biosVendor = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "BIOS vendor. Null = auto-detect.";
      };
      biosVersion = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "BIOS version. Null = auto-detect.";
      };
      biosDate = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "BIOS date. Null = auto-detect.";
      };
      biosRevision = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "BIOS revision hex. Null = auto-detect.";
      };
      smbiosManufacturer = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Processor manufacturer. Null = auto-detect.";
      };
      acpiOemId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACPI OEM ID (6 chars). Null = auto-detect from probe.";
      };
      acpiOemTableId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACPI OEM Table ID (8 chars). Null = auto-detect.";
      };
      acpiOemTableIdHex = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACPI OEM Table ID hex (for EDK2). Null = auto-detect.";
      };
      acpiOemRevision = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACPI OEM Revision hex. Null = auto-detect.";
      };
      acpiCreatorId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACPI Creator ID (4 chars). Null = auto-detect.";
      };
      acpiCreatorIdHex = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACPI Creator ID hex (for EDK2). Null = auto-detect.";
      };
      acpiCreatorRevision = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "ACPI Creator Revision hex. Null = auto-detect.";
      };
      acpiPmProfile = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "ACPI PM Profile (1=Desktop, 2=Mobile). Null = auto-detect.";
      };

      spoofModels = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Replace virtual device model strings with realistic names.";
      };
      spoofUsbSerials = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Randomize USB device serial strings in QEMU source at build time.";
      };
      ideModel = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      nvmeModel = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      cdModel = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      cfataModel = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };

      bootLogo = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a BMP file to use as the OVMF boot logo.
          Replaces the default EDK2 logo (a strong OVMF fingerprint).
          On a real system, copy your host's boot logo:
            sudo cat /sys/firmware/acpi/bgrt/image > boot-logo.bmp
        '';
      };

      injectSecureBootKeys = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Inject host Secure Boot keys (PK, KEK, db, dbx) into OVMF_VARS.fd
          at system activation. Makes the guest's Secure Boot chain match the host.
          Requires /sys/firmware/efi/efivars/ to be accessible.
        '';
      };

      generateSmbiosBin = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Generate smbios.bin from host DMI tables at activation.";
      };
    };

    network = {
      randomizeMac = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Randomize the libvirt default network bridge MAC (avoids 52:54:00 OUI fingerprint).";
      };

      subnet = lib.mkOption {
        type = lib.types.str;
        default = "10.0.0";
        description = ''
          Subnet prefix for the libvirt default network (avoids 192.168.122.x fingerprint).
          Will be used as: <subnet>.1 for gateway, <subnet>.2-254 for DHCP range.
        '';
      };
    };

    vm = {
      memory = lib.mkOption { type = lib.types.int; default = 16384; description = "VM memory in MiB."; };
      cores = lib.mkOption { type = lib.types.int; default = 4; description = "CPU cores."; };
      threads = lib.mkOption { type = lib.types.int; default = 2; description = "Threads per core."; };
      evdevInputs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Input devices for evdev passthrough.";
      };
      evdevGrabKey = lib.mkOption {
        type = lib.types.enum [ "ctrl-ctrl" "alt-alt" "shift-shift" "meta-meta" "scrolllock" "ctrl-scrolllock" ];
        default = "ctrl-ctrl";
      };
      pciPassthrough = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      audioBackend = lib.mkOption {
        type = lib.types.enum [ "none" "pipewire" "pulseaudio" "alsa" ];
        default = "pipewire";
      };
      isoPath = lib.mkOption { type = lib.types.nullOr lib.types.path; default = null; };
      diskPath = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      diskSize = lib.mkOption { type = lib.types.str; default = "64G"; };
      networkMac = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      enableHyperVPassthrough = lib.mkOption { type = lib.types.bool; default = false; };
      acpiTables = lib.mkOption { type = lib.types.listOf lib.types.path; default = [ ]; };
      useFakeBattery = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Include bundled fake battery ACPI SSDT.";
      };
      useSpoofedDevices = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Include bundled spoofed ACPI devices table (power button, EC, fan, AC adapter).";
      };
    };

    installUtilities = lib.mkOption { type = lib.types.bool; default = true; };
    installGuestScripts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install Windows guest anti-detection scripts to /share/barely-metal/.";
    };

    _internal = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      internal = true;
      visible = false;
    };
  };

  config = lib.mkIf cfg.enable {
    warnings = lib.optional (!hasProbe && !hasFacter) ''
      barelyMetal: No hardware data source configured.
      All spoofing values will use generic defaults — your VM will NOT match your host.

      Generate a probe file:
        sudo barely-metal-probe -o probe.json
      Then: barelyMetal.probeData = builtins.fromJSON (builtins.readFile ./probe.json);
    '';

    # User group membership
    users.users = lib.listToAttrs (map (user: {
      name = user;
      value = {
        extraGroups = [
          "kvm"
          "libvirtd"
          "input"
        ];
      };
    }) cfg.users);

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
        deployWrapper
        pkgs.swtpm
        pkgs.virt-manager
      ]
      ++ lib.optional cfg.installUtilities barelyMetalUtils
      ++ lib.optional cfg.installGuestScripts guestScripts;

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 root root -"
      "d ${stateDir}/firmware 0750 root root -"
    ];

    system.activationScripts.barelyMetal = {
      text =
        let
          virtFwVars = pkgs.python3Packages.virt-firmware or null;
        in
        ''
          mkdir -p ${stateDir}/firmware

          # Generate SMBIOS binary
          ${lib.optionalString spoofCfg.generateSmbiosBin ''
            if [ -f /sys/firmware/dmi/tables/smbios_entry_point ] && [ -f /sys/firmware/dmi/tables/DMI ]; then
              cd ${stateDir}/firmware
              ${smbiosSpoofer}/bin/barely-metal-smbios-spoofer || echo "Warning: SMBIOS spoofer failed"
              if [ -f smbios.bin ]; then
                chmod 644 smbios.bin
              fi
            fi
          ''}

          # Inject host Secure Boot keys into OVMF_VARS.fd
          ${lib.optionalString (spoofCfg.injectSecureBootKeys && virtFwVars != null) ''
            if [ -d /sys/firmware/efi/efivars ]; then
              VARS_SRC="${patchedOvmf}/FV/OVMF_VARS.fd"
              VARS_DST="${stateDir}/firmware/OVMF_VARS.fd"
              JSON_TMP=$(mktemp)

              # Extract EFI variables into JSON for virt-fw-vars
              {
                echo '['
                first=true
                for var in PK KEK db dbx PKDefault KEKDefault dbDefault dbxDefault; do
                  varpath="/sys/firmware/efi/efivars/$var-*"
                  for f in $varpath; do
                    [ -f "$f" ] || continue
                    guid=$(basename "$f" | sed "s/^$var-//")
                    attr=$(od -An -N4 -tu4 "$f" | tr -d ' ')
                    data=$(dd if="$f" bs=1 skip=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
                    if [ "$first" = true ]; then first=false; else echo ','; fi
                    echo "  {\"name\": \"$var\", \"guid\": \"$guid\", \"attr\": $attr, \"data\": \"$data\"}"
                  done
                done
                echo ']'
              } > "$JSON_TMP"

              ${virtFwVars}/bin/virt-fw-vars \
                --input "$VARS_SRC" \
                --output "$VARS_DST" \
                --secure-boot \
                --set-json "$JSON_TMP" 2>/dev/null || {
                  echo "Warning: Secure Boot key injection failed, using stock OVMF_VARS"
                  cp "$VARS_SRC" "$VARS_DST"
                }

              rm -f "$JSON_TMP"
              chmod 644 "$VARS_DST"
            else
              cp "${patchedOvmf}/FV/OVMF_VARS.fd" "${stateDir}/firmware/OVMF_VARS.fd"
              chmod 644 "${stateDir}/firmware/OVMF_VARS.fd"
            fi
          ''}

          ${lib.optionalString (!(spoofCfg.injectSecureBootKeys && virtFwVars != null)) ''
            cp "${patchedOvmf}/FV/OVMF_VARS.fd" "${stateDir}/firmware/OVMF_VARS.fd"
            chmod 644 "${stateDir}/firmware/OVMF_VARS.fd"
          ''}
        '';
    };

    # Libvirt network anti-fingerprinting
    system.activationScripts.barelyMetalNetwork = lib.mkIf cfg.network.randomizeMac {
      text = ''
        NETXML="/var/lib/libvirt/network/default.xml"
        if [ -f "$NETXML" ]; then
          RANDMAC="b0:4e:26:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
          ${pkgs.gnused}/bin/sed -i \
            -e "s|<mac address='[^']*'/>|<mac address='$RANDMAC'/>|" \
            -e "s|192\.168\.122|${cfg.network.subnet}|g" \
            "$NETXML" 2>/dev/null || true
        fi
      '';
    };

    barelyMetal._internal = {
      qemuPackage = patchedQemu;
      ovmfPackage = patchedOvmf;
      smbiosBinPath = "${stateDir}/firmware/smbios.bin";
      ovmfVarsPath = "${stateDir}/firmware/OVMF_VARS.fd";
      firmwareDir = "${stateDir}/firmware";
      autovirtSrc = autovirt;
      inherit resolvedCpu;
    };
  };
}
