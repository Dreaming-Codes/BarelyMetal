# BarelyMetal

A NixOS flake that builds a fully anti-detection KVM/QEMU virtualization stack. Your Windows guest VM will present hardware identifiers that match your actual host — ACPI tables, SMBIOS data, PCI vendor IDs, drive models, USB descriptors, UEFI firmware strings, Secure Boot certificates, and boot logos are all spoofed to look like bare metal.

Based on [AutoVirt](https://github.com/Scrut1ny/AutoVirt) by Scrut1ny.

## What it does

BarelyMetal patches QEMU and OVMF/EDK2 at build time with your host's real hardware fingerprint, then provides a NixOS module to declaratively configure the entire stack:

- **Patched QEMU** — Replaces all VirtIO/Red Hat/QEMU vendor IDs, device strings, USB descriptors, ACPI identifiers, EDID data, and SMBIOS defaults with realistic consumer hardware values matching your CPU vendor (AMD or Intel)
- **Patched OVMF** — Replaces firmware vendor strings, SMBIOS Type 0 entries, ACPI PCDs, EFI variable names, and the boot logo with your host's real values. Injects your host's Secure Boot keys (PK, KEK, db, dbx) into NVRAM
- **SMBIOS spoofing** — Dumps your host's real DMI tables at boot, scrubs UUIDs and serial numbers, and passes them to QEMU so the guest sees your actual motherboard/BIOS identity
- **ACPI table compilation** — Bundled fake battery and spoofed device tables are compiled with your host's OEM IDs patched in (no "BOCHS" or "_ASUS_" fingerprints)
- **VFIO GPU passthrough** — Declarative kernel params, modprobe config, driver blacklisting, with auto-detection from [nix-facter](https://github.com/numtide/nixos-facter)
- **VM deployment** — A `virt-install` wrapper that generates the full anti-detection XML: `kvm.hidden`, PMU off, VMPort off, MSR faulting, PS/2 disabled, CPU host-passthrough with hypervisor bit cleared, native TSC, disabled kvmclock, S3/S4 power states, NVMe with random serial, e1000e with spoofed MAC, evdev input, PipeWire audio, TPM emulation, optional Hyper-V passthrough
- **Kernel patch** — SVM/RDTSC timing patch that clears RDTSC/RDTSCP intercepts and handles CPUID leaf 0 to return `AuthenticAMD`. Applied via `boot.kernelPatches` so it works with any kernel (CachyOS, default, etc.)
- **Looking Glass** — KVMFR shared memory display with spoofed module vendor IDs
- **Network anti-fingerprinting** — Randomizes the libvirt bridge MAC and changes the DHCP subnet away from the detectable `192.168.122.x` default
- **Stable firmware paths** — OVMF_CODE.fd and OVMF_VARS.fd are copied to `/var/lib/barely-metal/firmware/` at activation, so VM XML references survive Nix garbage collection
- **Windows guest scripts** — Bundled PowerShell scripts for in-guest cleanup (registry QEMU artifacts, EDID serial scrubbing, machine ID randomization)

## Prerequisites

### nixos-facter (recommended)

[nixos-facter](https://github.com/numtide/nixos-facter) provides hardware auto-detection that BarelyMetal uses as a fallback for CPU vendor, BIOS info, and GPU driver detection. While not strictly required (the probe tool covers most needs), it's recommended for the best experience.

**1. Generate the facter report on your target machine:**

```sh
nix run github:numtide/nixos-facter -- -o facter.json
```

**2. Add nixos-facter to your flake inputs:**

```nix
# flake.nix
inputs = {
  nixos-facter-modules.url = "github:numtide/nixos-facter-modules";
};
```

**3. Include the module and point it at your report:**

```nix
# In your host configuration
{ inputs, ... }: {
  imports = [ inputs.nixos-facter-modules.nixosModules.facter ];
  facter.reportPath = ./facter.json;
}
```

The facter report should be regenerated if you change hardware (new GPU, different machine, etc.).

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

    # Recommended: nixos-facter for hardware auto-detection
    nixos-facter-modules.url = "github:numtide/nixos-facter-modules";
  };

  outputs = { nixpkgs, barely-metal, nixos-facter-modules, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        barely-metal.nixosModules.default
        nixos-facter-modules.nixosModules.facter
        ./configuration.nix
      ];
    };
  };
}
```

### 2. Probe your hardware

The probe tool reads ACPI tables, BIOS/DMI data, and CPU info that the Nix sandbox cannot access at build time. Run it once on your host:

```sh
sudo nix run github:Dreaming-Codes/BarelyMetal -- -o probe.json
```

If the host has a UEFI boot logo (most branded laptops/desktops), the probe tool will also save `boot-logo.bmp` alongside the JSON. This replaces the stock TianoCore/EDK2 logo — a strong OVMF fingerprint.

> Requires root — it reads `/sys/firmware/acpi/tables/FACP`, `/sys/class/dmi/id/*`, `/sys/firmware/efi/efivars/`, and `/sys/firmware/acpi/bgrt/image`.

Store the probe output in your NixOS config directory:

```sh
cp probe.json boot-logo.bmp /path/to/nixos-config/hosts/myhost/
```

### 3. Configure the module

```nix
# configuration.nix
{ config, lib, ... }:

{
  # Point nixos-facter at your hardware report
  facter.reportPath = ./facter.json;

  barelyMetal = {
    enable = true;

    # Pass your hardware probe data
    probeData = builtins.fromJSON (builtins.readFile ./probe.json);

    # Users to add to kvm, libvirtd, input groups
    users = [ "myuser" ];

    # Replace the OVMF boot logo (saved by barely-metal-probe)
    spoofing.bootLogo = ./boot-logo.bmp;

    vm = {
      memory = 16384;       # MiB
      cores = 6;
      threads = 2;
      audioBackend = "pipewire";

      # Laptop spoofing (fake ACPI battery + embedded controller/fan/power button)
      # useFakeBattery = true;
      # useSpoofedDevices = true;

      # Windows ISO for initial install
      # isoPath = /path/to/Win11.iso;

      # evdev input passthrough
      # evdevInputs = [
      #   "/dev/input/by-id/usb-Logitech_G502-event-mouse"
      #   "/dev/input/by-id/usb-Corsair_K70-event-kbd"
      # ];

      # Hyper-V passthrough mode (some anti-cheats prefer this over hidden KVM)
      # enableHyperVPassthrough = true;
    };

    # GPU passthrough (optional)
    # vfio = {
    #   enable = true;
    #   pciIds = [ "10de:2484" "10de:228b" ];
    # };

    # Looking Glass shared memory display (optional)
    # lookingGlass = {
    #   enable = true;
    #   user = "myuser";
    #   shmSize = 64;
    # };
  };
}
```

### 4. Kernel anti-timing patch (recommended)

The SVM patch clears RDTSC/RDTSCP intercepts and spoofs CPUID responses at the KVM level. It requires specific kernel command line parameters that increase power consumption (`idle=poll`, `mitigations=off`), so it's best placed in a boot specialization:

```nix
# configuration.nix
{
  # Use a NixOS specialisation so the power-hungry params
  # only apply when you boot into this entry
  specialisation.vm-antidetection.configuration = {
    barelyMetal.kernel.enable = true;
  };
}
```

This adds a `boot.kernelPatches` entry with the SVM patch to your existing kernel (no kernel replacement — works with CachyOS, mainline, or any other kernel) and sets the required kernel params:

- `mitigations=off` — disables CPU vulnerability mitigations (required for clean TSC)
- `idle=poll` — prevents C-state transitions that desync TSC
- `processor.max_cstate=1` — keeps the CPU in C1 (same reason)
- `tsc=reliable` — tells the kernel to trust the TSC

After rebuilding, select the `vm-antidetection` specialization from your bootloader when you need to run the VM.

### 5. Build and deploy the VM

After `nixos-rebuild switch`:

```sh
# Deploy the VM with all anti-detection settings
sudo barely-metal-deploy-vm

# Or customize at deploy time
sudo barely-metal-deploy-vm \
  --name "MyVM" \
  --display spice \
  --dry-run  # preview the virt-install command
```

The deploy script uses `virt-install` with the full set of anti-detection XML flags, pointing at your patched QEMU and OVMF binaries with pre-injected Secure Boot keys and SMBIOS tables. The ISO, memory, cores, and other settings come from your `barelyMetal.vm` config.

## Detection sources addressed

| Detection vector | How BarelyMetal handles it |
|---|---|
| CPUID hypervisor bit | `kvm.hidden=on`, hypervisor feature disabled |
| CPUID leaf 0 vendor string | Kernel SVM patch returns `AuthenticAMD` instead of `KVMKVMKVM` |
| RDTSC/RDTSCP timing | Kernel SVM patch clears intercepts for native TSC passthrough |
| KVM-specific MSRs | `msrs.unknown=fault` (inject #GP on unknown MSR access) |
| KVM paravirt clock | kvmclock and hypervclock disabled, native TSC |
| VMPort I/O backdoor | `vmport.state=off` |
| QEMU PCI vendor IDs | All `0x1af4`/`0x1b36`/`0x1234` replaced with AMD/Intel IDs |
| VirtIO device strings | Replaced with Realtek, Logitech, Samsung, MSI, etc. |
| USB device descriptors | QEMU manufacturer/product/serial strings replaced |
| SMBIOS tables | Host's real DMI tables passed through (UUIDs scrubbed) |
| ACPI OEM strings | Host's real FACP OEM ID, Table ID, Creator ID injected |
| ACPI PM Profile | Host's Desktop/Mobile profile replicated |
| ACPI battery/devices | Compiled with host OEM IDs (no "BOCHS" fingerprint) |
| OVMF firmware vendor | Host's BIOS vendor/version/date injected into EDK2 PCDs |
| OVMF boot logo | Replaced with host's BGRT image |
| OVMF Secure Boot chain | Host's PK/KEK/db/dbx keys injected into NVRAM |
| OVMF variable names | `certdb`/`certdbv` renamed to avoid fingerprinting |
| SMBIOS VM flag | `BIOSCharacteristicsExtensionBytes` VM bit cleared |
| IDE/NVMe model strings | Replaced with realistic consumer drive names |
| EDID monitor data | Spoofed to MSI G27C4X instead of "QEMU Monitor" |
| PS/2 controller | Disabled (USB HID only) |
| Memory balloon | Disabled (VirtIO memballoon removed) |
| Network MAC OUI | Uses host NIC's OUI instead of `52:54:00` |
| libvirt DHCP range | Changed from `192.168.122.x` to `10.0.0.x` |
| PMU | Disabled |
| Power states | S3/S4 enabled (real hardware supports these) |
| HDA audio vendor | Changed from VirtIO to Realtek |

## Data flow

```
sudo barely-metal-probe -o probe.json    # Run once, reads ACPI/DMI/CPU/BGRT
         |
         v
barelyMetal.probeData = builtins.fromJSON (...)
         |
         |---> QEMU build: patches + ACPI/SMBIOS/model spoofing
         |---> OVMF build: patches + firmware metadata + boot logo
         |---> ACPI build: fake_battery.dsl + spoofed_devices.dsl compiled with host OEM IDs
         |---> Activation: OVMF_CODE/VARS copied to stable paths, smbios.bin generated,
         |                 Secure Boot keys injected
         '---> Deploy: virt-install with full anti-detection XML
```

Values are resolved in priority order: **manual override** > **probeData** > **nix-facter** > **defaults**.

## Available packages

These are also usable standalone without the NixOS module:

| Package | Command | Description |
|---|---|---|
| `probe` (default) | `barely-metal-probe` | Hardware probe -> JSON + boot logo |
| `deploy` | `barely-metal-deploy` | `virt-install` wrapper with anti-detection |
| `qemu-patched` | `qemu-system-x86_64` | Patched QEMU (AMD) |
| `qemu-patched-intel` | `qemu-system-x86_64` | Patched QEMU (Intel) |
| `ovmf-patched` | -- | Patched OVMF firmware (AMD) |
| `ovmf-patched-intel` | -- | Patched OVMF firmware (Intel) |
| `smbios-spoofer` | `barely-metal-smbios-spoofer` | Host DMI table anonymizer |
| `utils` | `barely-metal-evdev`, `barely-metal-vbios-dumper`, `barely-metal-msr-check` | Utility scripts |
| `guest-scripts` | -- | Windows PowerShell scripts + ACPI tables for in-guest cleanup |

## Module options reference

### Core

| Option | Type | Default | Description |
|---|---|---|---|
| `barelyMetal.enable` | bool | `false` | Enable the full stack |
| `barelyMetal.probeData` | attrset | `{}` | Hardware probe JSON (parsed) |
| `barelyMetal.cpu` | `"amd"`/`"intel"`/null | null | CPU override (auto-detected from probe/facter) |
| `barelyMetal.users` | list of string | `[]` | Users to add to kvm/libvirtd/input |

### Spoofing

| Option | Type | Default | Description |
|---|---|---|---|
| `barelyMetal.spoofing.bootLogo` | path/null | null | BMP boot logo (replaces TianoCore logo) |
| `barelyMetal.spoofing.injectSecureBootKeys` | bool | `true` | Inject host Secure Boot keys at activation |
| `barelyMetal.spoofing.generateSmbiosBin` | bool | `true` | Generate smbios.bin from host DMI at activation |
| `barelyMetal.spoofing.spoofModels` | bool | `true` | Replace virtual device model strings |
| `barelyMetal.spoofing.spoofUsbSerials` | bool | `false` | Randomize USB serial strings at QEMU build time |
| `barelyMetal.spoofing.biosVendor` | string/null | null | BIOS vendor override (auto-detected) |
| `barelyMetal.spoofing.biosVersion` | string/null | null | BIOS version override (auto-detected) |
| `barelyMetal.spoofing.biosDate` | string/null | null | BIOS date override (auto-detected) |
| `barelyMetal.spoofing.acpiOemId` | string/null | null | ACPI OEM ID override (auto-detected) |
| `barelyMetal.spoofing.acpiPmProfile` | int/null | null | ACPI PM Profile: 1=Desktop, 2=Mobile (auto-detected) |

### Network

| Option | Type | Default | Description |
|---|---|---|---|
| `barelyMetal.network.randomizeMac` | bool | `true` | Randomize libvirt bridge MAC |
| `barelyMetal.network.subnet` | string | `"10.0.0"` | libvirt DHCP subnet prefix |

### VM

| Option | Type | Default | Description |
|---|---|---|---|
| `barelyMetal.vm.memory` | int | `16384` | VM memory in MiB |
| `barelyMetal.vm.cores` | int | `4` | CPU cores |
| `barelyMetal.vm.threads` | int | `2` | Threads per core |
| `barelyMetal.vm.audioBackend` | enum | `"pipewire"` | `none`, `pipewire`, `pulseaudio`, `alsa` |
| `barelyMetal.vm.isoPath` | path/null | null | Windows ISO path |
| `barelyMetal.vm.diskPath` | string/null | null | Custom disk image path |
| `barelyMetal.vm.diskSize` | string | `"64G"` | Disk size for new images |
| `barelyMetal.vm.evdevInputs` | list of string | `[]` | evdev input devices for passthrough |
| `barelyMetal.vm.evdevGrabKey` | enum | `"ctrl-ctrl"` | Grab toggle combo |
| `barelyMetal.vm.networkMac` | string/null | null | Fixed MAC (null = random with host OUI) |
| `barelyMetal.vm.enableHyperVPassthrough` | bool | `false` | Hyper-V passthrough mode |
| `barelyMetal.vm.useFakeBattery` | bool | `false` | Include fake battery ACPI SSDT |
| `barelyMetal.vm.useSpoofedDevices` | bool | `false` | Include spoofed devices (EC, fan, power button) |
| `barelyMetal.vm.acpiTables` | list of path | `[]` | Additional ACPI tables (.aml) |
| `barelyMetal.vm.pciPassthrough` | list of string | `[]` | PCI devices for passthrough |

### Kernel

| Option | Type | Default | Description |
|---|---|---|---|
| `barelyMetal.kernel.enable` | bool | `false` | Apply SVM anti-detection patch + required kernel params |
| `barelyMetal.kernel.svmPatch` | bool | `true` | Apply RDTSC/CPUID SVM patch |
| `barelyMetal.kernel.extraPatches` | list of path | `[]` | Additional kernel patches |

When `kernel.enable` is `true`, the following kernel parameters are added automatically: `mitigations=off idle=poll processor.max_cstate=1 tsc=reliable`. These are required for the SVM patch to function correctly but increase power consumption, so consider using a boot specialization.

### VFIO

| Option | Type | Default | Description |
|---|---|---|---|
| `barelyMetal.vfio.enable` | bool | `false` | VFIO GPU passthrough |
| `barelyMetal.vfio.pciIds` | list of string | `[]` | PCI IDs to bind to vfio-pci |

### Looking Glass

| Option | Type | Default | Description |
|---|---|---|---|
| `barelyMetal.lookingGlass.enable` | bool | `false` | KVMFR shared memory display |
| `barelyMetal.lookingGlass.user` | string | `""` | User for KVMFR device permissions |
| `barelyMetal.lookingGlass.shmSize` | int | `64` | Shared memory size in MiB |

## Credits

- [AutoVirt](https://github.com/Scrut1ny/AutoVirt) by Scrut1ny — the original project this is based on
- [nix-cachyos-kernel](https://github.com/xddxdd/nix-cachyos-kernel) by xddxdd — CachyOS kernel packaging for Nix
- [nixos-facter](https://github.com/numtide/nixos-facter) by Numtide — hardware detection for NixOS

## License

The patches and scripts from AutoVirt retain their original license. The Nix packaging is MIT.
