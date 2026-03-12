{
  lib,
  writeShellApplication,
  coreutils,
  libvirt,
  gnugrep,
  gnused,
  iproute2,
  gawk,
}:

writeShellApplication {
  name = "barely-metal-deploy";

  runtimeInputs = [
    coreutils
    libvirt
    gnugrep
    gnused
    iproute2
    gawk
  ];

  text = ''
    set -euo pipefail

    usage() {
      cat <<EOF
    Usage: barely-metal-deploy [OPTIONS]

    Generate and register a libvirt VM domain with full anti-detection settings.

    Required:
      --qemu PATH           Path to patched qemu-system-x86_64
      --ovmf-code PATH      Path to patched OVMF_CODE.fd
      --ovmf-vars PATH      Path to patched OVMF_VARS.fd

    VM config:
      --name NAME           VM domain name (default: BarelyMetal)
      --memory MIB          Memory in MiB (default: 16384)
      --cores N             CPU cores (default: 4)
      --threads N           Threads per core (default: 2)
      --disk PATH           Disk image path (auto-created if missing)
      --disk-size SIZE      Disk size for new images (default: 64G)
      --iso PATH            Windows ISO path
      --os-variant VARIANT  OS variant (default: win11)

    Anti-detection:
      --smbios-bin PATH     Path to smbios.bin
      --acpi-table PATH     Extra ACPI table (.aml), can be repeated
      --hyperv              Enable Hyper-V passthrough mode
      --cpu-vendor VENDOR   amd or intel (default: amd)

    Network:
      --mac MAC             MAC address (default: random with host OUI)

    Audio:
      --audio BACKEND       none, pipewire, pulseaudio, alsa (default: none)
      --audio-uid UID       User ID for PipeWire runtime dir

    Input:
      --evdev PATH          evdev input device, can be repeated
      --grab-toggle KEY     Grab toggle combo (default: ctrl-ctrl)

    Display:
      --display TYPE        spice, vnc, none (default: spice)

    Actions:
      --dry-run             Print virt-install command without executing
      --print-xml           Print generated XML without registering
      -h, --help            Show this help
    EOF
      exit 0
    }

    # Defaults
    DOMAIN_NAME="BarelyMetal"
    MEMORY=16384
    CORES=4
    THREADS=2
    DISK=""
    DISK_SIZE="64G"
    ISO=""
    OS_VARIANT="win11"
    QEMU_BIN=""
    OVMF_CODE=""
    OVMF_VARS=""
    SMBIOS_BIN=""
    ACPI_TABLES=()
    HYPERV=false
    CPU_VENDOR="amd"
    MAC=""
    AUDIO="none"
    AUDIO_UID=""
    EVDEV_DEVICES=()
    GRAB_TOGGLE="ctrl-ctrl"
    DISPLAY_TYPE="spice"
    DRY_RUN=false
    PRINT_XML=false

    while [ $# -gt 0 ]; do
      case "$1" in
        --name) DOMAIN_NAME="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --cores) CORES="$2"; shift 2 ;;
        --threads) THREADS="$2"; shift 2 ;;
        --disk) DISK="$2"; shift 2 ;;
        --disk-size) DISK_SIZE="$2"; shift 2 ;;
        --iso) ISO="$2"; shift 2 ;;
        --os-variant) OS_VARIANT="$2"; shift 2 ;;
        --qemu) QEMU_BIN="$2"; shift 2 ;;
        --ovmf-code) OVMF_CODE="$2"; shift 2 ;;
        --ovmf-vars) OVMF_VARS="$2"; shift 2 ;;
        --smbios-bin) SMBIOS_BIN="$2"; shift 2 ;;
        --acpi-table) ACPI_TABLES+=("$2"); shift 2 ;;
        --hyperv) HYPERV=true; shift ;;
        --cpu-vendor) CPU_VENDOR="$2"; shift 2 ;;
        --mac) MAC="$2"; shift 2 ;;
        --audio) AUDIO="$2"; shift 2 ;;
        --audio-uid) AUDIO_UID="$2"; shift 2 ;;
        --evdev) EVDEV_DEVICES+=("$2"); shift 2 ;;
        --grab-toggle) GRAB_TOGGLE="$2"; shift 2 ;;
        --display) DISPLAY_TYPE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --print-xml) PRINT_XML=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done

    # Validation
    if [ -z "$QEMU_BIN" ]; then
      echo "Error: --qemu is required" >&2; exit 1
    fi
    if [ -z "$OVMF_CODE" ]; then
      echo "Error: --ovmf-code is required" >&2; exit 1
    fi
    if [ -z "$OVMF_VARS" ]; then
      echo "Error: --ovmf-vars is required" >&2; exit 1
    fi

    # Generate random MAC with host OUI if not specified
    if [ -z "$MAC" ]; then
      DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}' || echo "")
      if [ -n "$DEFAULT_IFACE" ] && [ -f "/sys/class/net/$DEFAULT_IFACE/address" ]; then
        OUI=$(cut -d: -f1-3 < "/sys/class/net/$DEFAULT_IFACE/address")
      else
        OUI="b0:4e:26"
      fi
      MAC="$OUI:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
    fi

    # Generate random drive serial (use od to avoid SIGPIPE with pipefail)
    DRIVE_SERIAL=$(od -An -tx1 -N10 /dev/urandom | tr -d ' \n' | tr '[:lower:]' '[:upper:]')

    # CPU virtualization feature name
    if [ "$CPU_VENDOR" = "intel" ]; then
      CPU_VIRT_FEATURE="vmx"
    else
      CPU_VIRT_FEATURE="svm"
    fi

    # Hyper-V settings
    if [ "$HYPERV" = true ]; then
      HYPERV_CLOCK_STATUS="yes"
      CPU_FEATURE_HYPERVISOR="optional"
    else
      HYPERV_CLOCK_STATUS="no"
      CPU_FEATURE_HYPERVISOR="disable"
    fi

    # Build virt-install args
    args=(
      --connect qemu:///system
      --name "$DOMAIN_NAME"
      --osinfo "$OS_VARIANT"
      --memory "$MEMORY"

      # Boot: patched OVMF firmware
      --boot "cdrom,hd,menu=on,loader=$OVMF_CODE,loader.readonly=yes,loader.secure=yes,loader.type=pflash,nvram.template=$OVMF_VARS"

      # Hypervisor features — anti-detection
      --features "kvm.hidden.state=on"
      --features "pmu.state=off"
      --features "vmport.state=off"
      --features "smm.state=on"
      --features "msrs.unknown=fault"
      --xml "./features/ps2/@state=off"

      # CPU — host passthrough with anti-detection
      --cpu "host-passthrough,topology.sockets=1,topology.cores=$CORES,topology.threads=$THREADS"
      --xml "./cpu/@check=none"
      --xml "./cpu/@migratable=off"
      --xml "./cpu/topology/@dies=1"
      --xml "./cpu/topology/@clusters=1"
      --xml "./cpu/cache/@mode=passthrough"
      --xml "./cpu/maxphysaddr/@mode=passthrough"
      --xml "./cpu/feature[@name='$CPU_VIRT_FEATURE']/@policy=optional"
      --xml "./cpu/feature[@name='topoext']/@policy=optional"
      --xml "./cpu/feature[@name='invtsc']/@policy=optional"
      --xml "./cpu/feature[@name='hypervisor']/@policy=$CPU_FEATURE_HYPERVISOR"
      --xml "./cpu/feature[@name='ssbd']/@policy=disable"
      --xml "./cpu/feature[@name='amd-ssbd']/@policy=disable"
      --xml "./cpu/feature[@name='virt-ssbd']/@policy=disable"

      # Clock — anti-detection
      --xml "./clock/@offset=localtime"
      --xml "./clock/timer[@name='tsc']/@present=yes"
      --xml "./clock/timer[@name='tsc']/@mode=native"
      --xml "./clock/timer[@name='kvmclock']/@present=no"
      --xml "./clock/timer[@name='hypervclock']/@present=$HYPERV_CLOCK_STATUS"

      # Power management — anti-detection
      --xml "./pm/suspend-to-mem/@enabled=yes"
      --xml "./pm/suspend-to-disk/@enabled=yes"

      # Emulator path
      --xml "./devices/emulator=$QEMU_BIN"

      # NVMe disk with random serial
      --disk "size=500,bus=nvme,serial=$DRIVE_SERIAL,driver.cache=none,driver.io=native,driver.discard=unmap,blockio.logical_block_size=4096,blockio.physical_block_size=4096"
      --check "disk_size=off"

      # Network — e1000e with spoofed MAC
      --network "network=default,model=e1000e,mac=$MAC"

      # USB input devices (instead of PS/2)
      --input "mouse,bus=usb"
      --input "keyboard,bus=usb"

      # TPM emulation
      --tpm "backend.type=emulator,model=tpm-crb"

      # Display
      --graphics "$DISPLAY_TYPE"
      --video "vga"

      # Disable fingerprint-leaking devices
      --memballoon "none"
      --console "none"
      --channel "none"

      --noautoconsole
      --wait
    )

    # Hyper-V mode
    if [ "$HYPERV" = true ]; then
      args+=('--xml' './features/hyperv/@mode=passthrough')
    else
      args+=('--xml' 'xpath.delete=./features/hyperv')
    fi

    # ISO
    if [ -n "$ISO" ]; then
      args+=('--cdrom' "$ISO")
    fi

    # Custom disk path
    if [ -n "$DISK" ]; then
      args+=('--disk' "path=$DISK,size=$DISK_SIZE,bus=nvme,serial=$DRIVE_SERIAL,driver.cache=none,driver.io=native,driver.discard=unmap,blockio.logical_block_size=4096,blockio.physical_block_size=4096")
      # Override the default disk
      args=("''${args[@]/--disk \"size=500,/--disk \"path=$DISK,size=$DISK_SIZE,}")
    fi

    # SMBIOS binary
    if [ -n "$SMBIOS_BIN" ] && [ -f "$SMBIOS_BIN" ]; then
      args+=('--qemu-commandline=-smbios' "--qemu-commandline=file=$SMBIOS_BIN")
    fi

    # Extra ACPI tables
    for table in "''${ACPI_TABLES[@]}"; do
      args+=('--qemu-commandline=-acpitable' "--qemu-commandline=file=$table")
    done

    # Evdev input devices
    for dev in "''${EVDEV_DEVICES[@]}"; do
      extra_config=""
      if [[ "$dev" == *"kbd"* ]] || [[ "$dev" == *"keyboard"* ]]; then
        extra_config=",source.grab=all,source.repeat=on"
      fi
      args+=('--input' "type=evdev,source.dev=$dev,source.grabToggle=$GRAB_TOGGLE$extra_config")
    done

    # Audio
    case "$AUDIO" in
      pipewire)
        RUNTIME_UID="''${AUDIO_UID:-$(id -u)}"
        args+=(
          '--sound' 'model=ich9,audio.id=1'
          '--xml' './devices/audio/@id=1'
          '--xml' './devices/audio/@type=pipewire'
          '--xml' "./devices/audio/@runtimeDir=/run/user/$RUNTIME_UID"
          '--xml' './devices/audio/input/@mixingEngine=no'
          '--xml' './devices/audio/output/@mixingEngine=no'
        )
        ;;
      pulseaudio)
        args+=('--sound' 'model=ich9')
        ;;
      alsa)
        args+=('--sound' 'model=ich9')
        ;;
    esac

    if [ "$PRINT_XML" = true ]; then
      virt-install "''${args[@]}" --print-xml
      exit 0
    fi

    if [ "$DRY_RUN" = true ]; then
      echo "virt-install \\"
      for arg in "''${args[@]}"; do
        echo "  $arg \\"
      done
      exit 0
    fi

    echo "Deploying VM: $DOMAIN_NAME"
    virt-install "''${args[@]}"
    echo "VM '$DOMAIN_NAME' deployed successfully."
  '';
}
