{
  lib,
  python3,
  autovirt,
  makeWrapper,
}:

python3.pkgs.buildPythonApplication {
  pname = "barely-metal-smbios-spoofer";
  version = "1.0.0";
  format = "other";

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin $out/share/barely-metal
    cp ${autovirt}/resources/scripts/Linux/smbios_spoofer_cli.py $out/share/barely-metal/
    makeWrapper ${python3}/bin/python3 $out/bin/barely-metal-smbios-spoofer \
      --add-flags "$out/share/barely-metal/smbios_spoofer_cli.py"
  '';

  meta = {
    description = "Generate spoofed SMBIOS tables for QEMU anti-detection";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "barely-metal-smbios-spoofer";
  };
}
