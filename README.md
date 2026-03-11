# BarelyMetal

A NixOS flake that builds a fully anti-detection KVM/QEMU virtualization stack. Your Windows guest VM will present hardware identifiers that match your actual host — ACPI tables, SMBIOS data, PCI vendor IDs, drive models, USB descriptors, UEFI firmware strings, Secure Boot certificates, and boot logos are all spoofed to look like bare metal.

Based on [AutoVirt](https://github.com/Scrut1ny/AutoVirt) by Scrut1ny.

## What it does

BarelyMetal patches QEMU and OVMF/EDK2 at build time with your host's real hardware fingerprint, then provides a NixOS module to declaratively configure the entire stack:

- **Patched QEMU** — Replaces all VirtIO/Red Hat/QEMU vendor IDs, device strings, USB descriptors, ACPI identifiers, EDID data, and SMBIOS defaults with realistic consumer hardware values matching your CPU vendor (AMD or Intel)
- **Patched OVMF** — Replaces firmware vendor strings, SMBIOS Type 0 entries, ACPI PCDs, EFI variable names, and the boot logo with your host's real values. Injects your host's Secure Boot keys (PK, KEK, db, dbx) into NVRAM
- **SMBIOS spoofing** — Dumps your host's real DMI tables at boot, scrubs UUIDs and serial numbers, and passes them to QEMU so the guest sees your actual motherboard/BIOS identity
- **VFIO GPU passthrough** — Declarative kernel params, modprobe config, driver blacklisting, with auto-detection from [nix-facter](https://github.com/numtide/nixos-facter)
- **VM deployment** — A `virt-install` wrapper that generates the full anti-detection XML: `kvm.hidden`, PMU off, VMPort off, MSR faulting, PS/2 disabled, CPU host-passthrough with hypervisor bit cleared, native TSC, disabled kvmclock, S3/S4 power states, NVMe with random serial, e1000e with spoofed MAC, evdev input, PipeWire audio, TPM emulation, optional Hyper-V passthrough
- **CachyOS kernel** — Optional integration with [nix-cachyos-kernel](https://github.com/xddxdd/nix-cachyos-kernel) to apply the AutoVirt SVM/RDTSC timing patch
- **Looking Glass** — KVMFR shared memory display with spoofed module vendor IDs
- **Network anti-fingerprinting** — Randomizes the libvirt bridge MAC and changes the DHCP subnet away from the detectable `192.168.122.x` default
- **Windows guest scripts** — Bundled PowerShell scripts for in-guest cleanup (registry QEMU artifacts, EDID serial scrubbing, machine ID randomization)

## Setup

### 1. Add the flake input

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    barely-metal = {
      url = "github:your-user/BarelyMetal";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Optional: CachyOS kernel for SVM/RDTSC patch
    # nix-cachyos-kernel = {
    #   url = "github:xddxdd/nix-cachyos-kernel/release";
    # };
  };

  outputs = { nixpkgs, barely-metal, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        barely-metal.nixosModules.default
        ./configuration.nix

        # Optional: CachyOS kernel overlay
        # ({ pkgs, ... }: {
        #   nixpkgs.overlays = [ nix-cachyos-kernel.overlays.pinned ];
        # })
      ];
    };
  };
}
```

### 2. Probe your hardware

The probe tool reads ACPI tables, BIOS/DMI data, and CPU info that the Nix sandbox cannot access at build time. Run it once on your host:

```sh
nix run github:your-user/BarelyMetal -- -o probe.json

# or if you already have the flake locally:
nix run .#probe -- -o probe.json
```

> Requires root — it reads `/sys/firmware/acpi/tables/FACP`, `/sys/class/dmi/id/*`, and `/sys/firmware/efi/efivars/`.

The output is a JSON file containing your host's hardware identifiers. You can store it however you like:

- **Plain file** in your repo (it contains hardware model strings, not secrets per se)
- **Encrypted with sops-nix** if you consider hardware fingerprints sensitive
- **Inline** in your Nix config

### 3. Configure the module

```nix
# configuration.nix
{ config, pkgs, ... }:

{
  barelyMetal = {
    enable = true;

    # Pass your hardware probe data
    probeData = builtins.fromJSON (builtins.readFile ./probe.json);

    # Or from sops-nix:
    # probeData = builtins.fromJSON config.sops.placeholder."barely-metal/probe";

    # Users to add to kvm, libvirtd, input groups
    users = [ "myuser" ];

    # Optional: replace the OVMF boot logo (strong fingerprint)
    # Copy from your host: sudo cat /sys/firmware/acpi/bgrt/image > boot-logo.bmp
    # spoofing.bootLogo = ./boot-logo.bmp;

    vm = {
      memory = 16384;       # 16 GiB
      cores = 6;
      threads = 2;
      audioBackend = "pipewire";

      # evdev input passthrough
      # evdevInputs = [
      #   "/dev/input/by-id/usb-Logitech_G502-event-mouse"
      #   "/dev/input/by-id/usb-Corsair_K70-event-kbd"
      # ];

      # Hyper-V passthrough mode (some anti-cheats prefer this over hidden KVM)
      # enableHyperVPassthrough = true;

      # Bundled ACPI tables for laptop spoofing
      # useFakeBattery = true;
      # useSpoofedDevices = true;
    };

    # GPU passthrough
    # vfio = {
    #   enable = true;
    #   pciIds = [ "10de:2484" "10de:228b" ];
    #   # Drivers are auto-detected from nix-facter if available,
    #   # or specify manually:
    #   # blacklistDrivers = [ "nvidia" "nouveau" ];
    # };

    # Looking Glass
    # lookingGlass = {
    #   enable = true;
    #   user = "myuser";
    #   shmSize = 64;
    # };
  };

  # Optional: CachyOS kernel with SVM/RDTSC anti-timing patch
  # barelyMetal.kernel = {
  #   enable = true;
  #   variant = "linux-cachyos-bore";
  #   processorOpt = "x86_64-v3";
  # };

  # Optional: nix-facter for additional auto-detection (BIOS vendor, CPU, GPU drivers)
  # hardware.facter.reportPath = ./facter.json;
}
```

### 4. Build and deploy the VM

After `nixos-rebuild switch`:

```sh
# Deploy the VM with all anti-detection settings
sudo barely-metal-deploy-vm --iso ~/Downloads/Win11.iso

# Or customize at deploy time
sudo barely-metal-deploy-vm \
  --iso ~/Downloads/Win11.iso \
  --name "MyVM" \
  --display spice \
  --dry-run  # preview the virt-install command
```

The deploy script uses `virt-install` with the full set of anti-detection XML flags from AutoVirt, pointing at your patched QEMU and OVMF binaries with pre-injected Secure Boot keys and SMBIOS tables.

## Detection sources addressed

| Detection vector | How BarelyMetal handles it |
|---|---|
| CPUID hypervisor bit | `kvm.hidden=on`, hypervisor feature disabled |
| KVM-specific MSRs | `msrs.unknown=fault` (inject #GP on unknown MSR access) |
| KVM paravirt clock | kvmclock and hypervclock disabled, native TSC |
| VMPort I/O backdoor | `vmport.state=off` |
| QEMU PCI vendor IDs | All `0x1af4`/`0x1b36`/`0x1234` replaced with AMD/Intel IDs |
| VirtIO device strings | Replaced with Realtek, Logitech, Samsung, MSI, etc. |
| USB device descriptors | QEMU manufacturer/product/serial strings replaced |
| SMBIOS tables | Host's real DMI tables passed through (UUIDs scrubbed) |
| ACPI OEM strings | Host's real FACP OEM ID, Table ID, Creator ID injected |
| ACPI PM Profile | Host's Desktop/Mobile profile replicated |
| OVMF firmware vendor | Host's BIOS vendor/version/date injected into EDK2 PCDs |
| OVMF boot logo | Replaceable with host's BGRT image |
| OVMF Secure Boot chain | Host's PK/KEK/db/dbx keys injected into NVRAM |
| OVMF variable names | `certdb`→`dbcert` renamed to avoid fingerprinting |
| SMBIOS VM flag | `BIOSCharacteristicsExtensionBytes` VM bit cleared |
| IDE/NVMe model strings | Replaced with realistic consumer drive names |
| EDID monitor data | Spoofed to MSI G27C4X instead of "QEMU Monitor" |
| PS/2 controller | Disabled (USB HID only) |
| Memory balloon | Disabled (VirtIO memballoon removed) |
| Network MAC OUI | Uses host NIC's OUI instead of `52:54:00` |
| libvirt DHCP range | Changed from `192.168.122.x` to `10.0.0.x` |
| RDTSC timing | Optional kernel patch via CachyOS module |
| PMU | Disabled |
| Power states | S3/S4 enabled (real hardware supports these) |
| HDA audio vendor | Changed from VirtIO to Realtek |

## Data flow

```
sudo barely-metal-probe -o probe.json    # Run once, reads ACPI/DMI/CPU
         │
         ▼
barelyMetal.probeData = builtins.fromJSON (...)
         │
         ├──► QEMU build: patches + ACPI/SMBIOS/model spoofing
         ├──► OVMF build: patches + firmware metadata + boot logo
         ├──► Activation: smbios.bin generation + Secure Boot key injection
         └──► Deploy: virt-install with full anti-detection XML
```

Values are resolved in priority order: **manual override** > **probeData** > **nix-facter** > **defaults**.

## Available packages

These are also usable standalone without the NixOS module:

| Package | Command | Description |
|---|---|---|
| `probe` (default) | `barely-metal-probe` | Hardware probe → JSON |
| `deploy` | `barely-metal-deploy` | `virt-install` wrapper with anti-detection |
| `qemu-patched` | `qemu-system-x86_64` | Patched QEMU (AMD) |
| `qemu-patched-intel` | `qemu-system-x86_64` | Patched QEMU (Intel) |
| `ovmf-patched` | — | Patched OVMF firmware (AMD) |
| `ovmf-patched-intel` | — | Patched OVMF firmware (Intel) |
| `smbios-spoofer` | `barely-metal-smbios-spoofer` | Host DMI table anonymizer |
| `utils` | `barely-metal-evdev`, `barely-metal-vbios-dumper`, `barely-metal-msr-check` | Utility scripts |
| `guest-scripts` | — | Windows PowerShell scripts for in-guest cleanup |

## Module options reference

| Option | Type | Default | Description |
|---|---|---|---|
| `barelyMetal.enable` | bool | `false` | Enable the full stack |
| `barelyMetal.probeData` | attrset | `{}` | Hardware probe JSON (parsed) |
| `barelyMetal.cpu` | `"amd"`/`"intel"`/null | null | CPU override (auto-detected) |
| `barelyMetal.users` | list of string | `[]` | Users to add to kvm/libvirtd/input |
| `barelyMetal.spoofing.*` | various | null | Manual overrides for all spoofing values |
| `barelyMetal.spoofing.bootLogo` | path/null | null | Custom BMP boot logo |
| `barelyMetal.spoofing.spoofUsbSerials` | bool | `false` | Randomize USB serial strings |
| `barelyMetal.spoofing.injectSecureBootKeys` | bool | `true` | Inject host SB keys at activation |
| `barelyMetal.spoofing.generateSmbiosBin` | bool | `true` | Generate smbios.bin at activation |
| `barelyMetal.network.randomizeMac` | bool | `true` | Randomize libvirt bridge MAC |
| `barelyMetal.network.subnet` | string | `"10.0.0"` | libvirt DHCP subnet |
| `barelyMetal.vm.*` | various | — | VM config (memory, cores, audio, evdev, etc.) |
| `barelyMetal.vfio.enable` | bool | `false` | VFIO GPU passthrough |
| `barelyMetal.vfio.pciIds` | list of string | `[]` | PCI IDs to bind to vfio-pci |
| `barelyMetal.lookingGlass.enable` | bool | `false` | Looking Glass KVMFR display |
| `barelyMetal.kernel.enable` | bool | `false` | CachyOS kernel + SVM patch |

## Credits

- [AutoVirt](https://github.com/Scrut1ny/AutoVirt) by Scrut1ny — the original project this is based on
- [nix-cachyos-kernel](https://github.com/xddxdd/nix-cachyos-kernel) by xddxdd — CachyOS kernel packaging for Nix
- [nixos-facter](https://github.com/numtide/nixos-facter) by Numtide — hardware detection for NixOS

## License

The patches and scripts from AutoVirt retain their original license. The Nix packaging is MIT.
