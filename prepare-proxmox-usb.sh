cat > /root/proxmox-auto-install-fixed.sh << 'EOF'
#!/bin/bash
# ======================================================================
# PROXMOX AUTO INSTALL – FIXED VERSION (with filter)
# ======================================================================
# Fixed: added filter = "none" to [disk-setup] section
# ======================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
error_exit() { echo -e "${RED}❌ ERROR: $*${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}>>> $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
step() { echo -e "${CYAN}▶ $*${NC}"; }
ok() { echo -e "${GREEN}✅ $*${NC}"; }

AUTO=0
[[ "${1:-}" == "--auto" ]] && AUTO=1

confirm() {
    if [[ $AUTO -eq 1 ]]; then
        echo -e "${GREEN}✓${NC} $1 (y/n): y (auto-mode)"
        return 0
    fi
    local ans
    while true; do
        read -p "$1 (y/n): " ans
        ans=$(echo "$ans" | tr '[:upper:]' '[:lower:]' | xargs)
        [[ "$ans" == "y" || "$ans" == "yes" || "$ans" == "ano" ]] && return 0
        [[ "$ans" == "n" || "$ans" == "no" || "$ans" == "ne" ]] && return 1
        echo "Please answer 'y' or 'n'."
    done
}

normalize_disk() { [[ "$1" != /dev/* ]] && echo "/dev/$1" || echo "$1"; }
disk_exists() { [[ -b "$1" ]]; }
is_same_disk() { [[ "$(readlink -f "$1")" == "$(readlink -f "$2")" ]]; }

validate_keyboard() {
    local kb="$1"
    local valid=("de" "de-ch" "dk" "en-gb" "en-us" "es" "fi" "fr" "fr-be" "fr-ca" "fr-ch" "hu" "is" "it" "jp" "lt" "mk" "nl" "no" "pl" "pt" "pt-br" "se" "si" "tr")
    for v in "${valid[@]}"; do
        [[ "$kb" == "$v" ]] && return 0
    done
    return 1
}

# ---- FIX: Přidá filter ----
fix_answer_file() {
    local f="$1"
    
    # Fix source
    if grep -q '^source' "$f"; then
        local cur=$(grep '^source' "$f" | cut -d= -f2 | xargs | tr -d '"')
        if [[ "$cur" != "from-dhcp" && "$cur" != "from-answer" ]]; then
            sed -i 's/^source *= *.*/source = "from-dhcp"/' "$f"
        fi
    fi
    
    # Fix root-credentials -> root-password
    if grep -q '^\[root-credentials\]' "$f"; then
        local pass=$(sed -n '/^\[root-credentials\]/,/^\[/p' "$f" | grep '^password' | head -1 | cut -d= -f2 | xargs | tr -d '"')
        sed -i '/^\[root-credentials\]/,/^\[/d' "$f"
        if grep -q '^root-password' "$f"; then
            sed -i "s/^root-password *=.*/root-password = \"$pass\"/" "$f"
        else
            sed -i "/^\[global\]/a root-password = \"$pass\"" "$f"
        fi
    fi
    
    # Fix disk-setup (old root syntax)
    if grep -q '^root *= *{' "$f"; then
        local disk=$(grep '^root' "$f" | grep -o 'disk *= *"[^"]*"' | cut -d'"' -f2)
        local fs=$(grep '^root' "$f" | grep -o 'filesystem *= *"[^"]*"' | cut -d'"' -f2)
        [[ -z "$disk" ]] && disk="/dev/sda"
        [[ -z "$fs" ]] && fs="ext4"
        sed -i '/^root *= *{/d' "$f"
        if ! grep -q '^\[disk-setup\]' "$f"; then echo "" >> "$f"; echo "[disk-setup]" >> "$f"; fi
        if grep -q '^filesystem' "$f"; then sed -i "s/^filesystem *=.*/filesystem = \"$fs\"/" "$f"
        else sed -i "/^\[disk-setup\]/a filesystem = \"$fs\"" "$f"; fi
        if grep -q '^disk-list' "$f"; then sed -i "s/^disk-list *=.*/disk-list = [\"$disk\"]/" "$f"
        else sed -i "/^\[disk-setup\]/a disk-list = [\"$disk\"]" "$f"; fi
    fi
    
    # Fix ZFS raid
    if grep -q '^filesystem *= *"zfs"' "$f"; then
        sed -i '/^zfs.raid/d' "$f"
        sed -i "/^\[disk-setup\]/a zfs.raid = \"raid0\"" "$f"
    fi
    
    # ==== FIX: Přidá filter = "none" pokud chybí ====
    if grep -q '^\[disk-setup\]' "$f" && ! grep -q '^filter' "$f"; then
        warn "Přidávám filter = \"none\" do [disk-setup]"
        sed -i "/^\[disk-setup\]/a filter = \"none\"" "$f"
    fi
}

# ---- Main ----
if [[ $EUID -ne 0 ]]; then
    error_exit "Run as root: sudo $0"
fi

echo ""
echo "============================================================"
echo "  🔥 PROXMOX AUTO INSTALL – FIXED VERSION"
echo "============================================================"
echo ""

step "Installing dependencies..."
apt update -qq && apt install -y wget xorriso smartmontools proxmox-auto-install-assistant 2>/dev/null || {
    error_exit "Failed to install dependencies"
}
ok "Dependencies installed"

WORK_DIR="/root/proxmox-automation"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
CONFIG_FILE="$WORK_DIR/config.cfg"

if [[ -f "$CONFIG_FILE" ]] && [[ $AUTO -eq 1 ]]; then
    step "Loading saved config..."
    source "$CONFIG_FILE"
    [[ -z "${KEYBOARD:-}" ]] && KEYBOARD="en-us"
    [[ -z "${FILESYSTEM:-}" ]] && FILESYSTEM="ext4"
    [[ -z "${MAILTO:-}" ]] && MAILTO="root@${HOSTNAME:-localhost}"
    if [[ -n "${HOSTNAME:-}" && "$HOSTNAME" != *.* ]]; then
        HOSTNAME="${HOSTNAME}.local"
    fi
    ok "Config loaded: $HOSTNAME, $SYSTEM_DISK"
    CONFIG_LOADED=1
else
    CONFIG_LOADED=0
fi

if [[ $CONFIG_LOADED -eq 0 ]]; then
    if [[ $AUTO -eq 1 ]]; then
        error_exit "No config found. Run interactively first."
    fi
    
    step "Please provide installation parameters."
    echo ""
    lsblk -o NAME,SIZE,MODEL,MOUNTPOINT
    echo ""
    read -p "SYSTEM disk (e.g. nvme0n1, /dev/sda): " SYSTEM_DISK_RAW
    SYSTEM_DISK=$(normalize_disk "$SYSTEM_DISK_RAW")
    disk_exists "$SYSTEM_DISK" || error_exit "Disk $SYSTEM_DISK does not exist"
    read -p "DATA disks (space-separated, or empty): " data_input
    DATA_DISKS=()
    for d in $data_input; do
        d=$(normalize_disk "$d")
        disk_exists "$d" && DATA_DISKS+=("$d") || warn "$d does not exist (skipped)"
    done
    read -p "Hostname (FQDN, e.g. pve.domain.com): " HOSTNAME
    [[ -z "$HOSTNAME" ]] && error_exit "Hostname is required"
    [[ "$HOSTNAME" != *.* ]] && HOSTNAME="${HOSTNAME}.local"
    read -sp "Root password: " ROOT_PASSWORD; echo
    [[ -z "$ROOT_PASSWORD" ]] && error_exit "Password is required"
    read -sp "Confirm password: " ROOT_PASSWORD2; echo
    [[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD2" ]] && error_exit "Passwords do not match"
    read -p "Timezone (Europe/Prague): " TIMEZONE
    TIMEZONE="${TIMEZONE:-Europe/Prague}"
    echo "Valid keyboards: de, de-ch, dk, en-gb, en-us, es, fi, fr, fr-be, fr-ca, fr-ch, hu, is, it, jp, lt, mk, nl, no, pl, pt, pt-br, se, si, tr"
    read -p "Keyboard layout (en-us): " KEYBOARD
    KEYBOARD="${KEYBOARD:-en-us}"
    validate_keyboard "$KEYBOARD" || { warn "Invalid keyboard '$KEYBOARD' – using 'en-us'"; KEYBOARD="en-us"; }
    read -p "Country code (cz): " COUNTRY
    COUNTRY="${COUNTRY:-cz}"
    read -p "Email for notifications (root@$HOSTNAME): " MAILTO
    MAILTO="${MAILTO:-root@$HOSTNAME}"
    read -p "Network – DHCP (d) or static (s)? " net
    net=$(echo "$net" | tr '[:upper:]' '[:lower:]')
    if [[ "$net" == "d" || "$net" == "dhcp" ]]; then
        NET_SOURCE="dhcp"
    else
        NET_SOURCE="static"
        read -p "IP with prefix (e.g. 192.168.1.100/24): " IP_CIDR
        read -p "Gateway (e.g. 192.168.1.1): " GATEWAY
        read -p "DNS (e.g. 8.8.8.8): " DNS
    fi
    read -p "Filesystem (ext4/xfs/zfs) [ext4]: " FILESYSTEM
    FILESYSTEM="${FILESYSTEM:-ext4}"
    if [[ ! "$FILESYSTEM" =~ ^(ext4|xfs|zfs)$ ]]; then
        warn "Invalid filesystem '$FILESYSTEM' – using ext4"
        FILESYSTEM="ext4"
    fi
    confirm "Write ISO to USB?" && write_usb="a" || write_usb="n"
    
    cat > "$CONFIG_FILE" <<EOC
SYSTEM_DISK="$SYSTEM_DISK"
DATA_DISKS=(${DATA_DISKS[*]})
HOSTNAME="$HOSTNAME"
ROOT_PASSWORD="$ROOT_PASSWORD"
TIMEZONE="$TIMEZONE"
KEYBOARD="$KEYBOARD"
COUNTRY="$COUNTRY"
NET_SOURCE="$NET_SOURCE"
IP_CIDR="${IP_CIDR:-}"
GATEWAY="${GATEWAY:-}"
DNS="${DNS:-}"
FILESYSTEM="$FILESYSTEM"
MAILTO="$MAILTO"
write_usb="$write_usb"
EOC
    ok "Config saved to $CONFIG_FILE"
fi

echo ""
echo "============================================================"
echo "  📋 CONFIGURATION SUMMARY"
echo "============================================================"
echo "  Hostname:      $HOSTNAME"
echo "  System disk:   $SYSTEM_DISK"
[[ ${#DATA_DISKS[@]} -gt 0 ]] && echo "  Data disks:    ${DATA_DISKS[*]}"
echo "  Filesystem:    $FILESYSTEM"
echo "  Network:       $NET_SOURCE"
[[ "$NET_SOURCE" == "static" ]] && echo "  IP:            $IP_CIDR"
echo "  Keyboard:      $KEYBOARD"
echo "============================================================"
echo ""

step "Checking Proxmox ISO..."
ISO_FILE="$WORK_DIR/proxmox-ve_9.2-1.iso"
if [[ -f "$ISO_FILE" ]]; then
    ok "ISO already exists: $ISO_FILE"
else
    info "Downloading Proxmox ISO (1.6GB)..."
    wget -O "$ISO_FILE" "https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso" --progress=dot:giga || {
        error_exit "Download failed"
    }
    ok "ISO downloaded"
fi

step "Creating answer.toml with filter..."
ANSWER_FILE="$WORK_DIR/answer.toml"

if [[ "$NET_SOURCE" == "dhcp" ]]; then
    NET_SRC="from-dhcp"
    NET_EXTRA=""
else
    NET_SRC="from-answer"
    NET_EXTRA="
cidr = \"$IP_CIDR\"
gateway = \"$GATEWAY\"
dns = \"$DNS\""
fi

cat > "$ANSWER_FILE" <<EOA
[global]
keyboard = "$KEYBOARD"
country = "$COUNTRY"
fqdn = "$HOSTNAME"
timezone = "$TIMEZONE"
mailto = "$MAILTO"
root-password = "$ROOT_PASSWORD"

[network]
source = "$NET_SRC"$NET_EXTRA

[disk-setup]
filesystem = "$FILESYSTEM"
disk-list = ["$SYSTEM_DISK"]
filter = "none"
EOA

fix_answer_file "$ANSWER_FILE"
ok "answer.toml created with filter = \"none\""

CUSTOM_ISO="$WORK_DIR/proxmox-automated.iso"
if [[ -f "$CUSTOM_ISO" ]]; then
    ok "Automated ISO already exists: $CUSTOM_ISO"
else
    step "Creating automated ISO..."
    PREPARED=0
    for i in {1..3}; do
        info "Attempt $i/3..."
        rm -f "$CUSTOM_ISO"
        if output=$(proxmox-auto-install-assistant prepare-iso "$ISO_FILE" --fetch-from iso --answer-file "$ANSWER_FILE" --output "$CUSTOM_ISO" 2>&1); then
            if [[ -f "$CUSTOM_ISO" ]]; then
                ok "Automated ISO created: $CUSTOM_ISO"
                PREPARED=1
                break
            else
                warn "Command succeeded but file not created."
                echo "$output"
            fi
        else
            echo "$output"
            warn "Preparation failed."
        fi
        fix_answer_file "$ANSWER_FILE"
    done
    if [[ $PREPARED -eq 0 ]]; then
        warn "Failed to create automated ISO after 3 attempts."
        if confirm "Continue with original ISO (manual installation)?"; then
            CUSTOM_ISO="$ISO_FILE"
        else
            error_exit "Aborted by user"
        fi
    fi
fi

USB_WRITTEN_FLAG="$WORK_DIR/usb-written"
if [[ -f "$USB_WRITTEN_FLAG" ]]; then
    ok "USB already written (flag exists). Skipping."
else
    if [[ "$write_usb" == "a" ]]; then
        step "Detecting USB drives >=4GB..."
        USB_DEVICES=()
        while read -r dev; do
            if [[ -b "$dev" ]] && udevadm info --query=property --name="$dev" 2>/dev/null | grep -q "ID_BUS=usb"; then
                size=$(blockdev --getsize64 "$dev" | awk '{print int($1/1024/1024/1024)}')
                [[ $size -ge 4 ]] && USB_DEVICES+=("$dev:$size")
            fi
        done < <(lsblk -lno NAME | grep -E '^sd[a-z]$|^nvme[0-9]n[0-9]$' | sed 's/^/\/dev\//')
        
        [[ ${#USB_DEVICES[@]} -eq 0 ]] && error_exit "No USB >=4GB found"
        
        echo "Found USB drives:"
        for i in "${!USB_DEVICES[@]}"; do
            dev=$(echo "${USB_DEVICES[$i]}" | cut -d: -f1)
            size=$(echo "${USB_DEVICES[$i]}" | cut -d: -f2)
            model=$(udevadm info --query=property --name="$dev" | grep ID_MODEL= | cut -d= -f2 || echo "unknown")
            echo "  $((i+1))) $dev (${size}GB) - $model"
        done
        
        if [[ $AUTO -eq 1 ]]; then
            USB_DEVICE=$(echo "${USB_DEVICES[0]}" | cut -d: -f1)
            ok "Auto-selecting first USB: $USB_DEVICE"
        else
            read -p "Select number: " choice
            choice=$(echo "$choice" | xargs)
            [[ ! "$choice" =~ ^[0-9]+$ || "$choice" -lt 1 || "$choice" -gt ${#USB_DEVICES[@]} ]] && error_exit "Invalid choice"
            USB_DEVICE=$(echo "${USB_DEVICES[$((choice-1))]}" | cut -d: -f1)
        fi
        
        is_same_disk "$USB_DEVICE" "$SYSTEM_DISK" && error_exit "USB = system disk!"
        
        for part in $(lsblk -lno NAME "$USB_DEVICE" | grep -E "^${USB_DEVICE##*/}[0-9]" | sed 's/^/\/dev\//'); do
            mount | grep -q "$part" && umount "$part" 2>/dev/null || true
        done
        
        confirm "ERASE ALL DATA on $USB_DEVICE?" || error_exit "Aborted"
        
        step "Writing ISO to $USB_DEVICE... This may take 2-5 minutes."
        if dd bs=4M conv=fdatasync if="$CUSTOM_ISO" of="$USB_DEVICE" status=progress 2>&1; then
            sync
            touch "$USB_WRITTEN_FLAG"
            ok "ISO successfully written to $USB_DEVICE"
        else
            error_exit "dd write failed. Check USB device and try again."
        fi
    fi
fi

if [[ ${#DATA_DISKS[@]} -gt 0 ]]; then
    echo ""
    warn "DATA DISKS TO ERASE: ${DATA_DISKS[*]}"
    if confirm "Really erase ALL DATA on these disks?"; then
        for disk in "${DATA_DISKS[@]}"; do
            step "Erasing $disk..."
            wipefs -a "$disk" || true
            dd if=/dev/zero of="$disk" bs=1M count=200 conv=fdatasync status=progress || true
            parted -s "$disk" mklabel gpt || true
            parted -s "$disk" mkpart primary 0% 100% || true
            mkfs.ext4 -F "${disk}1" || true
            ok "$disk erased and formatted to ext4"
        done
    else
        warn "Skipped data disk erasure."
    fi
fi

echo ""
warn "ERASING SYSTEM DISK: $SYSTEM_DISK (including boot sector)"
if confirm "Are you absolutely sure?"; then
    step "Erasing $SYSTEM_DISK..."
    wipefs -a "$SYSTEM_DISK" || true
    dd if=/dev/zero of="$SYSTEM_DISK" bs=1M count=200 conv=fdatasync status=progress
    ok "System disk $SYSTEM_DISK erased."
else
    error_exit "Aborted by user"
fi

echo ""
step "Performing S.M.A.R.T. check..."
for disk in /dev/sd? /dev/nvme?n?; do
    [[ -b "$disk" ]] || continue
    echo "--- $disk ---"
    smartctl -i "$disk" | grep -E "Device Model|Serial|Firmware|SMART|User Capacity" 2>/dev/null || echo "Info not available"
    smartctl -H "$disk" 2>/dev/null | grep "SMART overall-health" || echo "SMART not supported"
done

echo ""
echo "============================================================"
echo "  ✅ DONE – READY FOR PROXMOX INSTALLATION"
echo "============================================================"
echo ""
echo "  📦 ISO:        $CUSTOM_ISO"
[[ "$write_usb" == "a" ]] && echo "  💾 USB:        $USB_DEVICE"
echo "  💻 System:     $SYSTEM_DISK (erased)"
[[ ${#DATA_DISKS[@]} -gt 0 ]] && echo "  💾 Data:       ${DATA_DISKS[*]} (erased)"
echo ""
echo "  ⚡ Next steps:"
echo "  1. Reboot server:        reboot"
echo "  2. Boot from USB ($USB_DEVICE)"
echo "  3. Proxmox installs automatically"
echo ""
echo "  📂 Config saved: $CONFIG_FILE"
echo "  🔄 To re-run:    sudo $0"
echo "  🤖 Auto mode:    sudo $0 --auto"
echo "============================================================"
EOF

chmod +x /root/proxmox-auto-install-fixed.sh
echo ""
echo "✅ OPRAVENÝ SKRIPT VYTVOŘEN: /root/proxmox-auto-install-fixed.sh"
echo ""
echo "SPUŠTĚNÍ:"
echo "  sudo /root/proxmox-auto-install-fixed.sh --auto"
