{
  lib,
  stdenv,
  autovirt,
}:

stdenv.mkDerivation {
  pname = "barely-metal-guest-scripts";
  version = "1.0.0";

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/share/barely-metal/guest-scripts/windows
    mkdir -p $out/share/barely-metal/acpi

    # Windows guest anti-detection scripts
    cp ${autovirt}/resources/scripts/Windows/edid-spoofer.ps1 $out/share/barely-metal/guest-scripts/windows/
    cp ${autovirt}/resources/scripts/Windows/identifier-spoofer.ps1 $out/share/barely-metal/guest-scripts/windows/
    cp ${autovirt}/resources/scripts/Windows/qemu-cleanup.ps1 $out/share/barely-metal/guest-scripts/windows/
    cp ${./power-fix.ps1} $out/share/barely-metal/guest-scripts/windows/power-fix.ps1

    # Bundled ACPI tables
    cp ${autovirt}/patches/QEMU/fake_battery.dsl $out/share/barely-metal/acpi/
    cp ${autovirt}/patches/QEMU/spoofed_devices.dsl $out/share/barely-metal/acpi/
    if [ -f ${autovirt}/patches/QEMU/spoofed_devices.aml ]; then
      cp ${autovirt}/patches/QEMU/spoofed_devices.aml $out/share/barely-metal/acpi/
    fi
  '';

  meta = {
    description = "BarelyMetal guest scripts and ACPI tables for anti-detection";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}
