{
  lib,
  stdenv,
  fetchurl,
  autovirt,
  qemu-src,
  cpu ? "amd",

  # Spoofing options (host-specific, passed from NixOS module)
  acpiOemId ? "ALASKA",
  acpiOemTableId ? "A M I   ",
  acpiCreatorId ? "ACPI",
  acpiPmProfile ? 1, # 1 = Desktop, 2 = Mobile
  smbiosManufacturer ? "Advanced Micro Devices, Inc.",
  spoofModels ? true,
  ideModel ? null, # random if null
  nvmeModel ? null,
  cdModel ? null,
  cfataModel ? null,

  # Build dependencies
  python3,
  pkg-config,
  ninja,
  meson,
  perl,
  flex,
  bison,
  makeWrapper,
  removeReferencesTo,
  dtc,
  glib,
  gnutls,
  zlib,
  pixman,
  vde2,
  lzo,
  snappy,
  libtasn1,
  libslirp,
  libcbor,
  curl,
  libcap_ng,
  libcap,
  attr,
  libaio,
  libusb1,
  usbredir,
  spice,
  spice-protocol,
  libepoxy,
  libdrm,
  virglrenderer,
  SDL2,
  SDL2_image,
  gtk3,
  gettext,
  vte,
  wrapGAppsHook3,
  libjpeg,
  libpng,
  libseccomp,
  numactl,
  liburing,
  fuse3,
  capstone,
  alsa-lib,
  pipewire,
  jack2,
  pulseaudio,
  mesa,
  libevdev,
}:

let
  cpuLower = lib.toLower cpu;
  patchFile =
    if cpuLower == "amd" then
      "${autovirt}/patches/QEMU/AMD-v10.2.0.patch"
    else
      "${autovirt}/patches/QEMU/Intel-v10.2.0.patch";

  defaultIdeModels = [
    "Samsung SSD 870 EVO 1TB"
    "WD Blue SN570 NVMe 500GB"
    "Crucial MX500 1TB"
    "Seagate BarraCuda 2TB"
    "Kingston A2000 NVMe 1TB"
    "Toshiba MQ04ABF100"
    "HGST Travelstar 7K1000"
    "Samsung SSD 980 PRO 2TB"
  ];

  defaultNvmeModels = [
    "Samsung 990 PRO 2TB"
    "WD Black SN850X 1TB"
    "Crucial T500 2TB"
    "SK Hynix Platinum P41 1TB"
    "Kingston FURY Renegade 2TB"
    "Sabrent Rocket 4 Plus 2TB"
    "Corsair MP600 PRO XT 4TB"
    "Samsung 980 PRO 1TB"
  ];

  defaultCdModels = [
    "HL-DT-ST BD-RE WH16NS60"
    "ASUS BW-16D1HT"
    "Pioneer BDR-XD07B"
    "LG BP60NB10"
    "Samsung SH-B123L"
  ];

  defaultCfataModels = [
    "Hitachi HMS360404D5CF00"
    "Micron MTFDDAK256MAM"
    "Samsung MZMPC128HBFU"
  ];

  selectedIdeModel = if ideModel != null then ideModel else builtins.head defaultIdeModels;
  selectedNvmeModel = if nvmeModel != null then nvmeModel else builtins.head defaultNvmeModels;
  selectedCdModel = if cdModel != null then cdModel else builtins.head defaultCdModels;
  selectedCfataModel = if cfataModel != null then cfataModel else builtins.head defaultCfataModels;

  pmProfileComment = if acpiPmProfile == 2 then "Mobile" else "Desktop";
in
stdenv.mkDerivation {
  pname = "barely-metal-qemu";
  version = "10.2.0-barely-metal";

  src = qemu-src;

  nativeBuildInputs = [
    python3
    pkg-config
    ninja
    meson
    perl
    flex
    bison
    makeWrapper
    removeReferencesTo
    wrapGAppsHook3
    dtc
  ];

  buildInputs = [
    glib
    gnutls
    zlib
    pixman
    vde2
    lzo
    snappy
    libtasn1
    libslirp
    libcbor
    curl
    libcap_ng
    libcap
    attr
    libaio
    libusb1
    usbredir
    spice
    spice-protocol
    libepoxy
    libdrm
    virglrenderer
    SDL2
    SDL2_image
    gtk3
    gettext
    vte
    libjpeg
    libpng
    libseccomp
    numactl
    liburing
    fuse3
    capstone
    alsa-lib
    pipewire
    jack2
    pulseaudio
    mesa
    libevdev
  ];

  dontUseMesonConfigure = true;

  postPatch = ''
    # Apply AutoVirt anti-detection patch
    patch -p1 < ${patchFile}

    # --- Dynamic spoofing (replaces AutoVirt's shell functions) ---

    # spoof_acpi: inject ACPI OEM identifiers
    sed -i \
      -e 's/\(#define ACPI_BUILD_APPNAME6 \)"[^"]*"/\1"${acpiOemId}"/' \
      -e 's/\(#define ACPI_BUILD_APPNAME8 \)"[^"]*"/\1"${acpiOemTableId}"/' \
      include/hw/acpi/aml-build.h

    sed -i 's/"ACPI"/"${acpiCreatorId}"/g' hw/acpi/aml-build.c

    # spoof_acpi: PM profile
    ${lib.optionalString (acpiPmProfile == 2) ''
      sed -i 's/1 \/\* Desktop \*\/, 1/2 \/* Mobile *\/, 1/' hw/acpi/aml-build.c
    ''}

    # spoof_smbios: inject processor manufacturer
    sed -i \
      "s/smbios_set_defaults(\"[^\"]*\",/smbios_set_defaults(\"${smbiosManufacturer}\",/" \
      hw/i386/fw_cfg.c

    # spoof_models: inject realistic drive model strings
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
  '';

  configurePhase = ''
    runHook preConfigure

    ./configure \
      --target-list=x86_64-softmmu \
      --prefix=$out \
      --enable-libusb \
      --enable-usb-redir \
      --enable-spice \
      --enable-spice-protocol \
      --enable-linux-io-uring \
      --enable-fuse \
      --enable-capstone \
      --enable-seccomp \
      --enable-numa \
      --enable-tpm \
      --enable-gtk \
      --enable-sdl \
      --enable-vnc \
      --enable-alsa \
      --enable-pipewire \
      --enable-jack \
      --enable-pulseaudio \
      --enable-opengl \
      --enable-virglrenderer \
      --enable-gnutls \
      --enable-tools \
      --disable-werror \
      --disable-docs \
      --disable-strip

    runHook postConfigure
  '';

  preBuild = "cd build";

  enableParallelBuilding = true;

  postInstall = ''
    # Create qemu-kvm symlink
    ln -s $out/bin/qemu-system-x86_64 $out/bin/qemu-kvm
  '';

  # Nix sandbox doesn't have /dev/kvm etc.
  doCheck = false;

  requiredSystemFeatures = [ "big-parallel" ];

  meta = {
    description = "QEMU with anti-VM-detection patches (BarelyMetal/AutoVirt)";
    homepage = "https://github.com/Scrut1ny/AutoVirt";
    license = lib.licenses.gpl2Plus;
    platforms = [ "x86_64-linux" ];
    mainProgram = "qemu-system-x86_64";
  };
}
