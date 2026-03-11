{
  self,
  autovirt,
  qemu-src,
  edk2-src,
}:

{
  imports = [
    (import ./vfio.nix)
    (import ./vm.nix {
      inherit
        self
        autovirt
        qemu-src
        edk2-src
        ;
    })
    (import ./looking-glass.nix)
    (import ./kernel.nix)
  ];
}
