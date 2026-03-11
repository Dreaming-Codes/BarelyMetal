{ lib }:

let
  inherit (lib)
    any
    head
    filter
    elem
    ;
in
rec {
  # --- nix-facter report helpers ---

  hasAmdCpu =
    report: any ({ vendor_name ? "", ... }: vendor_name == "AuthenticAMD") (report.hardware.cpu or [ ]);

  hasIntelCpu =
    report: any ({ vendor_name ? "", ... }: vendor_name == "GenuineIntel") (report.hardware.cpu or [ ]);

  detectCpuFromFacter =
    report: if hasAmdCpu report then "amd" else if hasIntelCpu report then "intel" else null;

  getBiosVendorFromFacter = report: (report.smbios.bios or { }).vendor or null;
  getBiosVersionFromFacter = report: (report.smbios.bios or { }).version or null;
  getBiosDateFromFacter = report: (report.smbios.bios or { }).date or null;

  getProcessorManufacturerFromFacter =
    report:
    let
      processors = report.smbios.processor or [ ];
      first = if processors != [ ] then head processors else { };
    in
    first.manufacturer or null;

  getGraphicsCards = report: report.hardware.graphics_card or [ ];

  getGpuDrivers =
    report:
    let
      cards = getGraphicsCards report;
    in
    lib.unique (lib.concatMap (d: d.driver_modules or [ ]) cards);

  # --- Probe JSON helpers ---

  getCpuFromProbe = probe: probe.cpu or null;

  getBiosVendorFromProbe = probe: (probe.bios or { }).vendor or null;
  getBiosVersionFromProbe = probe: (probe.bios or { }).version or null;
  getBiosDateFromProbe = probe: (probe.bios or { }).date or null;
  getBiosRevisionFromProbe = probe: (probe.bios or { }).revision or null;

  getProcessorManufacturerFromProbe = probe: (probe.smbios or { }).processor_manufacturer or null;

  getAcpiOemIdFromProbe = probe: (probe.acpi or { }).oem_id or null;
  getAcpiOemTableIdFromProbe = probe: (probe.acpi or { }).oem_table_id or null;
  getAcpiOemTableIdHexFromProbe = probe: (probe.acpi or { }).oem_table_id_hex or null;
  getAcpiOemRevisionFromProbe = probe: (probe.acpi or { }).oem_revision or null;
  getAcpiCreatorIdFromProbe = probe: (probe.acpi or { }).creator_id or null;
  getAcpiCreatorIdHexFromProbe = probe: (probe.acpi or { }).creator_id_hex or null;
  getAcpiCreatorRevisionFromProbe = probe: (probe.acpi or { }).creator_revision or null;
  getAcpiPmProfileFromProbe = probe: (probe.acpi or { }).pm_profile or null;

  hasBatteryFromProbe = probe: (probe.battery or { }).present or false;

  # --- Unified resolver: probe > facter > manual > default ---
  # First non-null wins.
  firstNonNull =
    values: default:
    let
      filtered = builtins.filter (v: v != null) values;
    in
    if filtered == [ ] then default else head filtered;
}
