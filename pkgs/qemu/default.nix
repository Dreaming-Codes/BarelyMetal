{
  lib,
  qemu,
  autovirt,
  cpu ? "amd",

  acpiOemId ? "ALASKA",
  acpiOemTableId ? "A M I   ",
  acpiCreatorId ? "ACPI",
  acpiPmProfile ? 1,
  smbiosManufacturer ? "Advanced Micro Devices, Inc.",
  spoofModels ? true,
  spoofUsbSerials ? false,
  ideModel ? null,
  nvmeModel ? null,
  cdModel ? null,
  cfataModel ? null,
}:

let
  cpuLower = lib.toLower cpu;
  patchFile =
    if cpuLower == "amd" then
      "${autovirt}/patches/QEMU/AMD-v10.2.0.patch"
    else
      "${autovirt}/patches/QEMU/Intel-v10.2.0.patch";

  selectedIdeModel =
    if ideModel != null then ideModel else "Samsung SSD 870 EVO 1TB";
  selectedNvmeModel =
    if nvmeModel != null then nvmeModel else "Samsung 990 PRO 2TB";
  selectedCdModel =
    if cdModel != null then cdModel else "HL-DT-ST BD-RE WH16NS60";
  selectedCfataModel =
    if cfataModel != null then cfataModel else "Hitachi HMS360404D5CF00";
in
(qemu.override {
  hostCpuTargets = [ "x86_64-softmmu" ];
  smbdSupport = false;
}).overrideAttrs (old: {
  pname = "barely-metal-qemu";

  patches = (old.patches or []) ++ [ patchFile ];

  postPatch = (old.postPatch or "") + ''
    # spoof_acpi: ACPI OEM identifiers
    sed -i \
      -e 's/\(#define ACPI_BUILD_APPNAME6 \)"[^"]*"/\1"${acpiOemId}"/' \
      -e 's/\(#define ACPI_BUILD_APPNAME8 \)"[^"]*"/\1"${acpiOemTableId}"/' \
      include/hw/acpi/aml-build.h

    sed -i 's/"ACPI"/"${acpiCreatorId}"/g' hw/acpi/aml-build.c

    ${lib.optionalString (acpiPmProfile == 2) ''
      sed -i 's/1 \/\* Desktop \*\/, 1/2 \/* Mobile *\/, 1/' hw/acpi/aml-build.c
    ''}

    # spoof_smbios: processor manufacturer
    sed -i \
      "s/smbios_set_defaults(\"[^\"]*\",/smbios_set_defaults(\"${smbiosManufacturer}\",/" \
      hw/i386/fw_cfg.c

    # spoof_models: drive model strings
    ${lib.optionalString spoofModels ''
      sed -i -E \
        -e 's/"HL-DT-ST BD-RE WH16NS60"/"${selectedCdModel}"/' \
        -e 's/"Hitachi HMS360404D5CF00"/"${selectedCfataModel}"/' \
        -e 's/"Samsung SSD 980 500GB"/"${selectedIdeModel}"/' \
        hw/ide/core.c

      sed -i -E \
        's/"NVMe Ctrl"/"${selectedNvmeModel}"/' \
        hw/nvme/ctrl.c
    ''}

    # spoof_serials: randomize USB device serial strings
    ${lib.optionalString spoofUsbSerials ''
      for f in hw/usb/*.c; do
        for pat in STRING_SERIALNUMBER STR_SERIALNUMBER STR_SERIAL_MOUSE STR_SERIAL_TABLET STR_SERIAL_KEYBOARD STR_SERIAL_COMPAT; do
          while IFS= read -r lineno; do
            serial=$(head -c 10 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 10 | tr 'a-f' 'A-F')
            sed -r -i "''${lineno}s/(\[\s*$pat\s*\]\s*=\s*\")[^\"]*(\")/\1$serial\2/" "$f"
          done < <(grep -n "$pat" "$f" | grep -oP '^\d+')
        done
      done
    ''}
  '';

  postInstall = (old.postInstall or "") + ''
    ln -sf $out/bin/qemu-system-x86_64 $out/bin/qemu-kvm
  '';

  meta = (old.meta or {}) // {
    description = "QEMU with anti-VM-detection patches (BarelyMetal/AutoVirt)";
    mainProgram = "qemu-system-x86_64";
  };
})
