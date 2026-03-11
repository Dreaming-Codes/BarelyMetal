{
  description = "BarelyMetal — NixOS module for anti-detection KVM/QEMU virtualization (based on AutoVirt)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    autovirt = {
      url = "github:Scrut1ny/AutoVirt";
      flake = false;
    };

    qemu-src = {
      url = "gitlab:qemu-project/qemu/v10.2.0";
      flake = false;
    };

    edk2-src = {
      url = "github:tianocore/edk2/edk2-stable202602";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      autovirt,
      qemu-src,
      edk2-src,
    }:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      nixosModules = {
        default = self.nixosModules.barelyMetal;
        barelyMetal = import ./modules {
          inherit
            self
            autovirt
            qemu-src
            edk2-src
            ;
        };
      };

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          callPackage = pkgs.callPackage;
        in
        {
          probe = callPackage ./pkgs/probe { };

          qemu-patched = callPackage ./pkgs/qemu {
            inherit autovirt qemu-src;
            cpu = "amd";
          };

          qemu-patched-intel = callPackage ./pkgs/qemu {
            inherit autovirt qemu-src;
            cpu = "intel";
          };

          ovmf-patched = callPackage ./pkgs/ovmf {
            inherit autovirt edk2-src;
            cpu = "amd";
          };

          ovmf-patched-intel = callPackage ./pkgs/ovmf {
            inherit autovirt edk2-src;
            cpu = "intel";
          };

          smbios-spoofer = callPackage ./pkgs/smbios-spoofer { inherit autovirt; };

          utils = callPackage ./pkgs/utils { inherit autovirt; };

          default = callPackage ./pkgs/probe { };
        }
      );

      devShells = forAllSystems (system: {
        default =
          let
            pkgs = pkgsFor system;
          in
          pkgs.mkShell {
            packages = with pkgs; [
              qemu
              libvirt
              virt-manager
              pciutils
              dmidecode
            ];
          };
      });
    };
}
