{
  lib,
  writeShellApplication,
  coreutils,
  dmidecode,
  gnused,
  gawk,
  util-linux,
  gnugrep,
  jq,
}:

writeShellApplication {
  name = "barely-metal-probe";

  runtimeInputs = [
    coreutils
    dmidecode
    gnused
    gawk
    util-linux
    gnugrep
    jq
  ];

  text = ''
    set -euo pipefail

    if [ "$(id -u)" -ne 0 ]; then
      echo "Error: barely-metal-probe must be run as root (needs access to ACPI tables and DMI)" >&2
      echo "Usage: sudo barely-metal-probe [-o /path/to/probe.json]" >&2
      exit 1
    fi

    OUTPUT=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o|--output) OUTPUT="$2"; shift 2 ;;
        -h|--help)
          echo "Usage: sudo barely-metal-probe [-o /path/to/probe.json]"
          echo ""
          echo "Probes host hardware (ACPI, DMI/SMBIOS, CPU) and outputs JSON."
          echo "The JSON file is consumed by the BarelyMetal NixOS module to"
          echo "build QEMU and OVMF with your host's real hardware identifiers."
          echo ""
          echo "Options:"
          echo "  -o, --output FILE   Write JSON to FILE (default: stdout)"
          echo ""
          echo "The output can be stored as-is or encrypted with sops/agenix."
          echo "Then reference it in your NixOS config:"
          echo "  barelyMetal.probeFile = ./probe.json;"
          exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done

    # --- ACPI FACP table ---
    FACP="/sys/firmware/acpi/tables/FACP"

    if [ -f "$FACP" ]; then
      ACPI_OEM_ID=$(dd if="$FACP" bs=1 skip=10 count=6 2>/dev/null | tr '\0' ' ')
      ACPI_OEM_TABLE_ID=$(dd if="$FACP" bs=1 skip=16 count=8 2>/dev/null | tr '\0' ' ')
      ACPI_CREATOR_ID=$(dd if="$FACP" bs=1 skip=28 count=4 2>/dev/null | tr '\0' ' ')
      ACPI_PM_PROFILE=$(dd if="$FACP" bs=1 skip=45 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')

      ACPI_OEM_TABLE_ID_HEX="0x$(dd if="$FACP" bs=1 skip=16 count=8 2>/dev/null \
        | od -An -tx1 | tr -d ' \n' \
        | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\8\7\6\5\4\3\2\1/')"

      ACPI_OEM_REVISION="0x$(dd if="$FACP" bs=1 skip=24 count=4 2>/dev/null \
        | od -An -tx1 | tr -d ' \n' \
        | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')"

      ACPI_CREATOR_ID_HEX="0x$(dd if="$FACP" bs=1 skip=28 count=4 2>/dev/null \
        | od -An -tx1 | tr -d ' \n' \
        | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')"

      ACPI_CREATOR_REVISION="0x$(dd if="$FACP" bs=1 skip=32 count=4 2>/dev/null \
        | od -An -tx1 | tr -d ' \n' \
        | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')"
    else
      echo "Warning: FACP table not found at $FACP — using safe defaults" >&2
      ACPI_OEM_ID="ALASKA"
      ACPI_OEM_TABLE_ID="A M I   "
      ACPI_CREATOR_ID="ACPI"
      ACPI_PM_PROFILE=1
      ACPI_OEM_TABLE_ID_HEX="0x20202020324B4445"
      ACPI_OEM_REVISION="0x00000002"
      ACPI_CREATOR_ID_HEX="0x20202020"
      ACPI_CREATOR_REVISION="0x01000013"
    fi

    # --- DMI/SMBIOS ---
    BIOS_VENDOR=$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null || echo "American Megatrends International, LLC.")
    BIOS_VERSION=$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo "1.0")
    BIOS_DATE=$(cat /sys/class/dmi/id/bios_date 2>/dev/null || echo "01/01/2024")

    BIOS_REV_RAW=$(dmidecode -t0 2>/dev/null | grep "BIOS Revision:" | awk '{print $3}' || echo "1.0")
    BIOS_REV_MAJOR=$(echo "$BIOS_REV_RAW" | cut -d. -f1)
    BIOS_REV_MINOR=$(echo "$BIOS_REV_RAW" | cut -d. -f2)
    BIOS_REVISION=$(printf "0x%04x%04x" "$BIOS_REV_MAJOR" "$BIOS_REV_MINOR")

    PROCESSOR_MFR=$(dmidecode --string processor-manufacturer 2>/dev/null || echo "Unknown")

    # --- CPU ---
    if grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
      CPU_VENDOR="amd"
    elif grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
      CPU_VENDOR="intel"
    else
      CPU_VENDOR="amd"
    fi

    # --- Battery SSDT (laptop detection) ---
    HAS_BATTERY=false
    BATTERY_SSDT=""
    for ssdt in /sys/firmware/acpi/tables/SSDT*; do
      if [ -f "$ssdt" ] && grep -qa -e "Battery" -e "BAT0" -e "BAT1" "$ssdt" 2>/dev/null; then
        HAS_BATTERY=true
        BATTERY_SSDT="$ssdt"
        break
      fi
    done

    # --- Build JSON with jq for proper escaping ---
    JSON=$(jq -n \
      --arg cpu "$CPU_VENDOR" \
      --arg acpi_oem_id "$ACPI_OEM_ID" \
      --arg acpi_oem_table_id "$ACPI_OEM_TABLE_ID" \
      --arg acpi_oem_table_id_hex "$ACPI_OEM_TABLE_ID_HEX" \
      --arg acpi_oem_revision "$ACPI_OEM_REVISION" \
      --arg acpi_creator_id "$ACPI_CREATOR_ID" \
      --arg acpi_creator_id_hex "$ACPI_CREATOR_ID_HEX" \
      --arg acpi_creator_revision "$ACPI_CREATOR_REVISION" \
      --argjson acpi_pm_profile "$ACPI_PM_PROFILE" \
      --arg bios_vendor "$BIOS_VENDOR" \
      --arg bios_version "$BIOS_VERSION" \
      --arg bios_date "$BIOS_DATE" \
      --arg bios_revision "$BIOS_REVISION" \
      --arg processor_manufacturer "$PROCESSOR_MFR" \
      --argjson has_battery "$HAS_BATTERY" \
      --arg battery_ssdt_path "$BATTERY_SSDT" \
      '{
        cpu: $cpu,
        acpi: {
          oem_id: $acpi_oem_id,
          oem_table_id: $acpi_oem_table_id,
          oem_table_id_hex: $acpi_oem_table_id_hex,
          oem_revision: $acpi_oem_revision,
          creator_id: $acpi_creator_id,
          creator_id_hex: $acpi_creator_id_hex,
          creator_revision: $acpi_creator_revision,
          pm_profile: $acpi_pm_profile
        },
        bios: {
          vendor: $bios_vendor,
          version: $bios_version,
          date: $bios_date,
          revision: $bios_revision
        },
        smbios: {
          processor_manufacturer: $processor_manufacturer
        },
        battery: {
          present: $has_battery,
          ssdt_path: $battery_ssdt_path
        }
      }')

    if [ -n "$OUTPUT" ]; then
      echo "$JSON" > "$OUTPUT"
      echo "Probe written to: $OUTPUT" >&2
      echo "Add to your NixOS config:  barelyMetal.probeFile = ./$OUTPUT;" >&2
    else
      echo "$JSON"
    fi
  '';
}
