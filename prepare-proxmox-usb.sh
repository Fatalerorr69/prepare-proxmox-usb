cat > /root/prepare-proxmox-usb.sh << 'EOF'
#!/bin/bash
# ======================================================================
# ULTIMATE FINAL – PŘÍPRAVA PRO AUTOMATICKOU INSTALACI PROXMOXu
# ======================================================================
# Opravy:
#   - ZFS raid: používáme "raid0" pro jeden disk
#   - Odstraňujeme duplicitní klíče
#   - Lepší detekce chyb a opravy
# ======================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
error_exit() { echo -e "${RED}❌ CHYBA: $*${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}>>> $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }

confirm_yn() {
    local ans
    while true; do
        read -p "$1 (y/n): " ans
        ans=$(echo "$ans" | tr '[:upper:]' '[:lower:]' | xargs)
        [[ "$ans" == "y" || "$ans" == "yes" ]] && return 0
        [[ "$ans" == "n" || "$ans" == "no" ]] && return 1
        echo "Odpovězte 'y' nebo 'n'."
    done
}

normalize_disk() { [[ "$1" != /dev/* ]] && echo "/dev/$1" || echo "$1"; }
disk_exists() { [[ -b "$1" ]]; }
is_same_disk() { [[ "$(readlink -f "$1")" == "$(readlink -f "$2")" ]]; }

# ---- Opravné funkce ----
fix_source() {
    local f="$1"
    if grep -q '^source' "$f"; then
        local cur=$(grep '^source' "$f" | cut -d= -f2 | xargs | tr -d '"')
        if [[ "$cur" != "from-dhcp" && "$cur" != "from-answer" ]]; then
            warn "Opravuji source: '$cur' -> 'from-dhcp'"
            sed -i 's/^source *= *.*/source = "from-dhcp"/' "$f"
        fi
    fi
}

fix_root_credentials() {
    local f="$1"
    if grep -q '^\[root-credentials\]' "$f"; then
        warn "Převádím [root-credentials] na root-password v [global]"
        local pass=$(sed -n '/^\[root-credentials\]/,/^\[/p' "$f" | grep '^password' | head -1 | cut -d= -f2 | xargs | tr -d '"')
        [[ -z "$pass" ]] && pass=$(grep -A2 '^\[root-credentials\]' "$f" | grep 'password' | head -1 | cut -d= -f2 | xargs | tr -d '"')
        sed -i '/^\[root-credentials\]/,/^\[/d' "$f"
        if grep -q '^root-password' "$f"; then
            sed -i "s/^root-password *=.*/root-password = \"$pass\"/" "$f"
        else
            sed -i "/^\[global\]/a root-password = \"$pass\"" "$f"
        fi
    fi
}

fix_disk_setup() {
    local f="$1"
    # Oprava staré syntaxe root = { ... }
    if grep -q '^root *= *{' "$f"; then
        warn "Opravuji starou syntaxi root = { ... }"
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
    # Oprava ZFS raid: použijeme "raid0" pro jeden disk
    if grep -q '^filesystem *= *"zfs"' "$f"; then
        # Odstraníme všechny existující zfs.raid řádky (aby nedošlo k duplicitě)
        sed -i '/^zfs.raid/d' "$f"
        # Přidáme správnou hodnotu
        sed -i "/^\[disk-setup\]/a zfs.raid = \"raid0\"" "$f"
        warn "Nastavuji zfs.raid = \"raid0\" (pro jeden disk)"
    fi
}

validate_answer() {
    local f="$1" err=0
    for key in keyboard country fqdn timezone mailto root-password source filesystem disk-list; do
        if ! grep -q "^$key" "$f"; then
            echo "❌ Chybí: $key"; err=1
        fi
    done
    if grep -q '^source' "$f"; then
        local src=$(grep '^source' "$f" | cut -d= -f2 | xargs | tr -d '"')
        [[ "$src" != "from-dhcp" && "$src" != "from-answer" ]] && echo "❌ Neplatné source: $src" && err=1
    fi
    return $err
}

# ---- Hlavní ----
if [[ $EUID -ne 0 ]]; then error_exit "Spusťte jako root: sudo $0"; fi

info "Instaluji závislosti..."
apt update && apt install -y wget xorriso smartmontools proxmox-auto-install-assistant || error_exit "Instalace selhala."

WORK_DIR="/root/proxmox-automation"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

CONFIG_FILE="$WORK_DIR/config.cfg"
USE_EXISTING=0
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Nalezena konfigurace $CONFIG_FILE"
    if confirm_yn "Chcete ji použít a přeskočit dotazování?"; then
        source "$CONFIG_FILE"
        [[ -z "${KEYBOARD:-}" ]] && KEYBOARD="en-us"
        [[ -z "${FILESYSTEM:-}" ]] && FILESYSTEM="ext4"
        [[ -z "${MAILTO:-}" ]] && MAILTO="root@${HOSTNAME:-localhost}"
        if [[ -n "${HOSTNAME:-}" && "$HOSTNAME" != *.* ]]; then
            warn "Doplňuji .local k hostname"
            HOSTNAME="${HOSTNAME}.local"
        fi
        USE_EXISTING=1
    fi
fi

if [[ $USE_EXISTING -eq 0 ]]; then
    echo ""
    info "Zadejte požadované informace"
    lsblk -o NAME,SIZE,MODEL,MOUNTPOINT
    read -p "SYSTÉMOVÝ disk (např. nvme0n1, /dev/sda): " SYSTEM_DISK_RAW
    SYSTEM_DISK=$(normalize_disk "$SYSTEM_DISK_RAW")
    disk_exists "$SYSTEM_DISK" || error_exit "Disk neexistuje"
    read -p "DATOVÉ disky (mezera, nebo prázdné): " data_input
    DATA_DISKS=()
    for d in $data_input; do
        d=$(normalize_disk "$d")
        disk_exists "$d" && DATA_DISKS+=("$d") || warn "$d neexistuje"
    done
    read -p "Hostname (FQDN): " HOSTNAME
    [[ -z "$HOSTNAME" ]] && error_exit "Hostname je povinný"
    [[ "$HOSTNAME" != *.* ]] && HOSTNAME="${HOSTNAME}.local"
    read -sp "Root heslo: " ROOT_PASSWORD; echo
    [[ -z "$ROOT_PASSWORD" ]] && error_exit "Heslo je povinné"
    read -sp "Potvrďte: " ROOT_PASSWORD2; echo
    [[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD2" ]] && error_exit "Hesla se neshodují"
    read -p "Časové pásmo (Europe/Prague): " TIMEZONE
    TIMEZONE="${TIMEZONE:-Europe/Prague}"
    echo "Dostupné klávesnice: de en-us cz ..."
    read -p "Kód klávesnice (en-us): " KEYBOARD
    KEYBOARD="${KEYBOARD:-en-us}"
    read -p "Kód země (cz): " COUNTRY
    COUNTRY="${COUNTRY:-cz}"
    read -p "E-mail pro notifikace (root@$HOSTNAME): " MAILTO
    MAILTO="${MAILTO:-root@$HOSTNAME}"
    read -p "Síť – DHCP (d) nebo statická (s)? " net
    net=$(echo "$net" | tr '[:upper:]' '[:lower:]')
    if [[ "$net" == "d" || "$net" == "dhcp" ]]; then
        NET_SOURCE="dhcp"
    else
        NET_SOURCE="static"
        read -p "IP s prefixem: " IP_CIDR
        read -p "Brána: " GATEWAY
        read -p "DNS: " DNS
    fi
    read -p "Souborový systém (ext4/xfs/zfs) [ext4]: " FILESYSTEM
    FILESYSTEM="${FILESYSTEM:-ext4}"
    confirm_yn "Zapsat ISO na USB?" && write_usb="a" || write_usb="n"
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
fi

# ISO
ISO_FILE="$WORK_DIR/proxmox-ve_9.2-1.iso"
if [[ ! -f "$ISO_FILE" ]]; then
    info "Stahuji ISO..."
    wget -O "$ISO_FILE" "https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso" || error_exit "Stažení selhalo"
fi

# answer.toml
ANSWER_FILE="$WORK_DIR/answer.toml"
info "Vytvářím answer.toml"

if [[ "$NET_SOURCE" == "dhcp" ]]; then
    NET_SRC="from-dhcp"; NET_EXTRA=""
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
EOA

# Opravy a validace
fix_source "$ANSWER_FILE"
fix_root_credentials "$ANSWER_FILE"
fix_disk_setup "$ANSWER_FILE"

validate_answer "$ANSWER_FILE" || {
    warn "answer.toml neprošel validací"
    if confirm_yn "Chcete upravit ručně (nano)?"; then
        nano "$ANSWER_FILE"
        fix_source "$ANSWER_FILE"; fix_root_credentials "$ANSWER_FILE"; fix_disk_setup "$ANSWER_FILE"
        validate_answer "$ANSWER_FILE" || error_exit "Stále chybný"
    else
        error_exit "Nelze pokračovat"
    fi
}

# Příprava ISO – max 3 pokusy
CUSTOM_ISO="$WORK_DIR/proxmox-automated.iso"
PREPARED=0
for i in {1..3}; do
    info "Pokus $i/3: vytvářím ISO..."
    rm -f "$CUSTOM_ISO"
    if output=$(proxmox-auto-install-assistant prepare-iso "$ISO_FILE" --fetch-from iso --answer-file "$ANSWER_FILE" --output "$CUSTOM_ISO" 2>&1); then
        if [[ -f "$CUSTOM_ISO" ]]; then
            info "ISO vytvořeno: $CUSTOM_ISO"
            PREPARED=1
            break
        else
            warn "Soubor neexistuje, ale příkaz skončil úspěšně."
            echo "$output"
            # Detekce chyb a opravy
            if grep -q "unknown variant" <<< "$output" && grep -q "zfs.raid" <<< "$output"; then
                warn "Chybná hodnota zfs.raid – opravuji na 'raid0'"
                sed -i '/^zfs.raid/d' "$ANSWER_FILE"
                sed -i "/^\[disk-setup\]/a zfs.raid = \"raid0\"" "$ANSWER_FILE"
            elif grep -q "duplicate key" <<< "$output" && grep -q "raid" <<< "$output"; then
                warn "Duplicitní klíč zfs.raid – odstraňuji duplicity"
                sed -i '/^zfs.raid/d' "$ANSWER_FILE"
                sed -i "/^\[disk-setup\]/a zfs.raid = \"raid0\"" "$ANSWER_FILE"
            elif grep -q "root-credentials" <<< "$output"; then
                fix_root_credentials "$ANSWER_FILE"
            elif grep -q "unknown variant" <<< "$output"; then
                fix_source "$ANSWER_FILE"
            elif grep -q "unknown field" <<< "$output"; then
                fix_disk_setup "$ANSWER_FILE"
            else
                if confirm_yn "Opravit answer.toml ručně?"; then
                    nano "$ANSWER_FILE"
                    fix_source "$ANSWER_FILE"; fix_root_credentials "$ANSWER_FILE"; fix_disk_setup "$ANSWER_FILE"
                fi
            fi
        fi
    else
        echo "$output"
        warn "Příprava selhala"
        if grep -q "unknown variant" <<< "$output" && grep -q "zfs.raid" <<< "$output"; then
            warn "Chybná hodnota zfs.raid – opravuji na 'raid0'"
            sed -i '/^zfs.raid/d' "$ANSWER_FILE"
            sed -i "/^\[disk-setup\]/a zfs.raid = \"raid0\"" "$ANSWER_FILE"
        elif grep -q "duplicate key" <<< "$output" && grep -q "raid" <<< "$output"; then
            warn "Duplicitní klíč zfs.raid – odstraňuji duplicity"
            sed -i '/^zfs.raid/d' "$ANSWER_FILE"
            sed -i "/^\[disk-setup\]/a zfs.raid = \"raid0\"" "$ANSWER_FILE"
        elif grep -q "root-credentials" <<< "$output"; then
            fix_root_credentials "$ANSWER_FILE"
        elif grep -q "unknown variant" <<< "$output"; then
            fix_source "$ANSWER_FILE"
        elif grep -q "unknown field" <<< "$output"; then
            fix_disk_setup "$ANSWER_FILE"
        else
            if confirm_yn "Opravit answer.toml ručně?"; then
                nano "$ANSWER_FILE"
                fix_source "$ANSWER_FILE"; fix_root_credentials "$ANSWER_FILE"; fix_disk_setup "$ANSWER_FILE"
            fi
        fi
    fi
done

if [[ $PREPARED -eq 0 ]]; then
    warn "Po 3 pokusech se nepodařilo vytvořit automatické ISO."
    if confirm_yn "Pokračovat s původním ISO (bez automatické instalace)?"; then
        CUSTOM_ISO="$ISO_FILE"
    else
        error_exit "Ukončeno"
    fi
fi

# Zápis na USB
if [[ "$write_usb" == "a" ]]; then
    info "Hledám USB >=4GB..."
    USB_DEVICES=()
    while read -r dev; do
        if [[ -b "$dev" ]] && udevadm info --query=property --name="$dev" 2>/dev/null | grep -q "ID_BUS=usb"; then
            size=$(blockdev --getsize64 "$dev" | awk '{print int($1/1024/1024/1024)}')
            [[ $size -ge 4 ]] && USB_DEVICES+=("$dev:$size")
        fi
    done < <(lsblk -lno NAME | grep -E '^sd[a-z]$|^nvme[0-9]n[0-9]$' | sed 's/^/\/dev\//')
    [[ ${#USB_DEVICES[@]} -eq 0 ]] && error_exit "Žádný USB nenalezen"
    echo "Nalezené USB:"
    for i in "${!USB_DEVICES[@]}"; do
        dev=$(echo "${USB_DEVICES[$i]}" | cut -d: -f1)
        size=$(echo "${USB_DEVICES[$i]}" | cut -d: -f2)
        model=$(udevadm info --query=property --name="$dev" | grep ID_MODEL= | cut -d= -f2 || echo "neznámý")
        echo "  $((i+1))) $dev (${size}GB) - $model"
    done
    read -p "Vyberte číslo: " choice
    choice=$(echo "$choice" | xargs)
    [[ ! "$choice" =~ ^[0-9]+$ || "$choice" -lt 1 || "$choice" -gt ${#USB_DEVICES[@]} ]] && error_exit "Neplatná volba"
    USB_DEVICE=$(echo "${USB_DEVICES[$((choice-1))]}" | cut -d: -f1)
    is_same_disk "$USB_DEVICE" "$SYSTEM_DISK" && error_exit "USB = systémový disk!"
    for part in $(lsblk -lno NAME "$USB_DEVICE" | grep -E "^${USB_DEVICE##*/}[0-9]" | sed 's/^/\/dev\//'); do
        mount | grep -q "$part" && umount "$part" 2>/dev/null || true
    done
    confirm_yn "SMAZAT VŠECHNA DATA na $USB_DEVICE?" || error_exit "Zrušeno"
    dd bs=4M conv=fdatasync if="$CUSTOM_ISO" of="$USB_DEVICE" status=progress || error_exit "Zápis selhal"
    sync
    info "✅ ISO zapsáno na $USB_DEVICE"
fi

# Vymazání datových disků
if [[ ${#DATA_DISKS[@]} -gt 0 ]]; then
    warn "Mažu datové disky: ${DATA_DISKS[*]}"
    confirm_yn "Opravdu?" && {
        for disk in "${DATA_DISKS[@]}"; do
            info "Mažu $disk"
            wipefs -a "$disk" || true
            dd if=/dev/zero of="$disk" bs=1M count=200 conv=fdatasync status=progress || true
            parted -s "$disk" mklabel gpt || true
            parted -s "$disk" mkpart primary 0% 100% || true
            mkfs.ext4 -F "${disk}1" || true
        done
    }
fi

# Vymazání systémového disku
warn "MAŽU SYSTÉMOVÝ DISK: $SYSTEM_DISK (včetně boot sektoru)"
confirm_yn "Jste si jistý?" && {
    wipefs -a "$SYSTEM_DISK" || true
    dd if=/dev/zero of="$SYSTEM_DISK" bs=1M count=200 conv=fdatasync status=progress
    info "✅ Systémový disk vymazán"
} || error_exit "Zrušeno"

# SMART kontrola
info "S.M.A.R.T. kontrola"
for disk in /dev/sd? /dev/nvme?n?; do
    [[ -b "$disk" ]] || continue
    echo "--- $disk ---"
    smartctl -i "$disk" | grep -E "Device Model|Serial|Firmware|SMART|User Capacity" || echo "Není dostupné"
    smartctl -H "$disk" 2>/dev/null | grep "SMART overall-health" || echo "SMART nedostupný"
done

echo ""
echo "=========================================="
echo "   HOTOVO – PŘIPRAVENO K INSTALACI"
echo "=========================================="
echo "ISO: $CUSTOM_ISO"
[[ "$write_usb" == "a" ]] && echo "USB: $USB_DEVICE"
echo "Systémový disk: $SYSTEM_DISK (vymazán)"
echo "Restartujte a nabootujte z USB."
echo "Konfigurace: $CONFIG_FILE"
EOF

chmod +x /root/prepare-proxmox-usb.sh
echo "Skript byl vytvořen jako /root/prepare-proxmox-usb.sh"
