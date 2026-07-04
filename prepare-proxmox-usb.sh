#!/bin/bash
# =============================================================================
# prepare-proxmox-usb.sh  –  Příprava bootovacího USB s automatickou instalací
#                            Proxmoxu. Spouští se na existujícím Proxmoxu.
# =============================================================================
set -euo pipefail

# ---- Barvy ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

error_exit() { echo -e "${RED}❌ CHYBA: $*${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}>>> $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }

# ---- Oprávnění ----
if [[ $EUID -ne 0 ]]; then
    error_exit "Tento skript musí být spuštěn jako root. Použijte: sudo $0"
fi

# ---- Pomocná funkce pro normalizaci cesty k disku ----
normalize_disk() {
    local disk="$1"
    if [[ "$disk" != /dev/* ]]; then
        disk="/dev/$disk"
    fi
    echo "$disk"
}

# ---- Instalace závislostí ----
info "Instaluji potřebné balíčky..."
apt update
apt install -y wget xorriso smartmontools proxmox-auto-install-assistant 2>/dev/null || {
    warn "Některé balíčky se nepodařilo nainstalovat – pokračuji s dostupnými."
}

# ---- Pracovní adresář ----
WORK_DIR="/root/proxmox-usb-prep"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ---- Pokus o načtení existující konfigurace ----
CONFIG_FILE="$WORK_DIR/config.cfg"
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Nalezena existující konfigurace v $CONFIG_FILE"
    read -p "Chcete ji použít? (a/n): " use_config
    if [[ "$use_config" == "a" ]]; then
        source "$CONFIG_FILE"
        info "Konfigurace načtena."
        # Přeskočíme dotazování – použijeme hodnoty z configu
        SYSTEM_DISK="${SYSTEM_DISK:-}"
        DATA_DISKS=("${DATA_DISKS[@]}")
        HOSTNAME="${HOSTNAME:-}"
        ROOT_PASSWORD="${ROOT_PASSWORD:-}"
        TIMEZONE="${TIMEZONE:-}"
        KEYBOARD="${KEYBOARD:-}"
        COUNTRY="${COUNTRY:-}"
        NET_SOURCE="${NET_SOURCE:-}"
        IP_CIDR="${IP_CIDR:-}"
        GATEWAY="${GATEWAY:-}"
        DNS="${DNS:-}"
        FILESYSTEM="${FILESYSTEM:-ext4}"
        USE_EXISTING_CONFIG=1
    else
        USE_EXISTING_CONFIG=0
    fi
else
    USE_EXISTING_CONFIG=0
fi

# ---- Pokud nebyla načtena konfigurace, zeptáme se uživatele ----
if [[ $USE_EXISTING_CONFIG -eq 0 ]]; then
    info "Zadejte prosím parametry pro instalaci Proxmoxu."

    # Zobrazení disků
    echo ""
    echo "Seznam disků v systému:"
    lsblk -o NAME,SIZE,MODEL,MOUNTPOINT
    echo ""

    # Systémový disk – zadání i bez /dev/
    read -p "Zadejte cestu k SYSTÉMOVÉMU disku (např. nvme0n1, /dev/sda): " SYSTEM_DISK_RAW
    SYSTEM_DISK=$(normalize_disk "$SYSTEM_DISK_RAW")
    [[ -b "$SYSTEM_DISK" ]] || error_exit "Disk $SYSTEM_DISK neexistuje."

    # Datové disky (volitelné) – zadání i bez /dev/
    read -p "Zadejte DATOVÉ disky k vymazání (oddělené mezerou, např. sdb sdc), nebo nechte prázdné: " DATA_DISKS_RAW
    DATA_DISKS=()
    if [[ -n "$DATA_DISKS_RAW" ]]; then
        for d in $DATA_DISKS_RAW; do
            d=$(normalize_disk "$d")
            if [[ -b "$d" ]]; then
                DATA_DISKS+=("$d")
            else
                warn "Disk $d neexistuje – přeskočeno."
            fi
        done
    fi

    # Základní nastavení
    read -p "Hostname (FQDN, např. pve.mojedomena.cz): " HOSTNAME
    [[ -n "$HOSTNAME" ]] || error_exit "Hostname nesmí být prázdný."

    read -sp "Root heslo: " ROOT_PASSWORD
    echo ""
    [[ -n "$ROOT_PASSWORD" ]] || error_exit "Heslo nesmí být prázdné."
    read -sp "Potvrďte root heslo: " ROOT_PASSWORD2
    echo ""
    [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD2" ]] || error_exit "Hesla se neshodují."

    read -p "Časové pásmo (např. Europe/Prague): " TIMEZONE
    read -p "Rozložení klávesnice (např. cs): " KEYBOARD
    read -p "Kód země (např. cz): " COUNTRY

    # Síť
    read -p "Síť – DHCP (d) nebo statická IP (s)? " net_choice
    if [[ "$net_choice" == "d" ]]; then
        NET_SOURCE="dhcp"
    else
        NET_SOURCE="static"
        read -p "IP adresa s prefixem (např. 192.168.1.100/24): " IP_CIDR
        read -p "Brána (např. 192.168.1.1): " GATEWAY
        read -p "DNS server (např. 8.8.8.8): " DNS
    fi

    # Souborový systém
    read -p "Souborový systém pro systém (ext4 / xfs / zfs): " FILESYSTEM
    [[ "$FILESYSTEM" =~ ^(ext4|xfs|zfs)$ ]] || FILESYSTEM="ext4"

    # Uložení konfigurace
    cat > "$CONFIG_FILE" <<EOF
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
EOF
    info "Konfigurace uložena do $CONFIG_FILE"
fi

# -----------------------------------------------------------------------------
# Stažení Proxmox ISO
# -----------------------------------------------------------------------------
ISO_URL="https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso"
ISO_FILE="$WORK_DIR/$(basename "$ISO_URL")"
if [[ -f "$ISO_FILE" ]]; then
    info "Proxmox ISO již existuje: $ISO_FILE"
else
    info "Stahuji Proxmox ISO z $ISO_URL ..."
    wget -O "$ISO_FILE" "$ISO_URL" || error_exit "Stažení ISO selhalo."
fi

# -----------------------------------------------------------------------------
# Vytvoření answer.toml
# -----------------------------------------------------------------------------
ANSWER_FILE="$WORK_DIR/answer.toml"
info "Vytvářím answer.toml: $ANSWER_FILE"
if [[ "$NET_SOURCE" == "dhcp" ]]; then
    NET_SECTION="source = \"dhcp\""
else
    NET_SECTION="source = \"static\"
cidr = \"$IP_CIDR\"
gateway = \"$GATEWAY\"
dns = \"$DNS\""
fi

cat > "$ANSWER_FILE" <<EOF
[global]
keyboard = "$KEYBOARD"
country = "$COUNTRY"
fqdn = "$HOSTNAME"
timezone = "$TIMEZONE"

[network]
$NET_SECTION

[disk-setup]
root = { disk = "$SYSTEM_DISK", filesystem = "$FILESYSTEM" }

[root-credentials]
password = "$ROOT_PASSWORD"
EOF

# -----------------------------------------------------------------------------
# Příprava automatického ISO
# -----------------------------------------------------------------------------
CUSTOM_ISO="$WORK_DIR/proxmox-automated.iso"
info "Vytvářím vlastní ISO s automatickou instalací..."
proxmox-auto-install-assistant prepare-iso "$ISO_FILE" \
    --fetch-from iso \
    --answer-file "$ANSWER_FILE" \
    --output "$CUSTOM_ISO" || error_exit "Příprava ISO selhala."

# -----------------------------------------------------------------------------
# Detekce USB disku
# -----------------------------------------------------------------------------
info "Detekuji dostupné USB flash disky (min. 4 GB)..."
USB_DEVICES=()
while read -r dev; do
    if [[ -b "$dev" ]]; then
        # Ověříme, že je to USB zařízení
        if udevadm info --query=property --name="$dev" 2>/dev/null | grep -q "ID_BUS=usb"; then
            SIZE_BYTES=$(blockdev --getsize64 "$dev")
            SIZE_GB=$((SIZE_BYTES / 1024 / 1024 / 1024))
            if [[ $SIZE_GB -ge 4 ]]; then
                USB_DEVICES+=("$dev:$SIZE_GB")
            fi
        fi
    fi
done < <(lsblk -lno NAME | grep -E '^sd[a-z]$|^nvme[0-9]n[0-9]$' | sed 's/^/\/dev\//')

if [[ ${#USB_DEVICES[@]} -eq 0 ]]; then
    error_exit "Nebyl nalezen žádný USB disk >=4 GB. Vložte USB a zkuste znovu."
fi

echo "Nalezené USB disky:"
for i in "${!USB_DEVICES[@]}"; do
    dev=$(echo "${USB_DEVICES[$i]}" | cut -d: -f1)
    size=$(echo "${USB_DEVICES[$i]}" | cut -d: -f2)
    model=$(udevadm info --query=property --name="$dev" | grep ID_MODEL= | cut -d= -f2 || echo "neznámý")
    echo "  $((i+1))) $dev  (${size} GB) - $model"
done
read -p "Vyberte číslo USB disku pro zápis ISO: " choice
if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#USB_DEVICES[@]} ]]; then
    error_exit "Neplatná volba."
fi
TARGET_USB=$(echo "${USB_DEVICES[$((choice-1))]}" | cut -d: -f1)
info "Vybraný USB disk: $TARGET_USB"

# Odpojení případných připojených oddílů
for part in $(lsblk -lno NAME "$TARGET_USB" | grep -E "^${TARGET_USB##*/}[0-9]" | sed 's/^/\/dev\//'); do
    if mount | grep -q "$part"; then
        umount "$part" || warn "Nepodařilo se odpojit $part"
    fi
done

# -----------------------------------------------------------------------------
# Zápis ISO na USB
# -----------------------------------------------------------------------------
info "Zapisuji automatické ISO na $TARGET_USB ... (tím smažete všechna data na tomto USB)"
read -p "Pro potvrzení napište 'ANO': " confirm
[[ "$confirm" == "ANO" ]] || error_exit "Zápis zrušen."

dd bs=4M conv=fdatasync if="$CUSTOM_ISO" of="$TARGET_USB" status=progress
sync
info "✅ ISO bylo úspěšně zapsáno na USB."

# -----------------------------------------------------------------------------
# Vymazání datových disků (pokud byly zadány)
# -----------------------------------------------------------------------------
if [[ ${#DATA_DISKS[@]} -gt 0 ]]; then
    echo ""
    warn "BYLY VYBRÁNY DATOVÉ DISKY K VYMAZÁNÍ: ${DATA_DISKS[*]}"
    read -p "Opravdu chcete TRVALE SMAZAT VŠECHNA DATA na těchto discích? (ANO): " confirm
    [[ "$confirm" == "ANO" ]] || warn "Vymazání datových disků přeskočeno."

    for disk in "${DATA_DISKS[@]}"; do
        info "Mažu disk: $disk"
        wipefs -a "$disk"
        dd if=/dev/zero of="$disk" bs=1M count=200 conv=fdatasync status=progress
        parted -s "$disk" mklabel gpt
        parted -s "$disk" mkpart primary 0% 100%
        mkfs.ext4 -F "${disk}1"
        info "✅ Disk $disk byl vymazán a naformátován."
    done
fi

# -----------------------------------------------------------------------------
# S.M.A.R.T. kontrola všech disků
# -----------------------------------------------------------------------------
info "Provádím S.M.A.R.T. kontrolu všech disků..."
for disk in /dev/sd? /dev/nvme?n?; do
    [[ -b "$disk" ]] || continue
    echo "-------------------------------------------------------------"
    echo "Disk: $disk"
    smartctl -i "$disk" | grep -E "Device Model|Serial Number|Firmware Version|SMART support|User Capacity"
    STATUS=$(smartctl -H "$disk" | grep "SMART overall-health" | awk '{print $6}')
    if [[ "$STATUS" == "PASSED" ]]; then
        echo "  S.M.A.R.T. stav: ✅ PASSED"
    else
        echo "  S.M.A.R.T. stav: ❌ $STATUS (pozor!)"
    fi
    smartctl -A "$disk" | grep -E "Temperature_Celsius|Wear_Leveling_Count|Reallocated_Sector|Current_Pending_Sector" || true
done

# -----------------------------------------------------------------------------
# Závěrečné instrukce
# -----------------------------------------------------------------------------
echo ""
echo "============================================================="
echo "   HOTOVO – PŘIPRAVENO K INSTALACI"
echo "============================================================="
echo ""
echo "✅ Bootovací USB s automatickou instalací Proxmoxu bylo vytvořeno:"
echo "   $TARGET_USB"
echo ""
echo "✅ Datové disky byly vymazány (pokud byly vybrány)."
echo "✅ S.M.A.R.T. kontrola proběhla."
echo ""
echo "➡️  Nyní proveďte RESTART serveru a nabootujte z tohoto USB disku."
echo "   Instalace Proxmoxu proběhne zcela automaticky podle vašich odpovědí."
echo ""
echo "⚠️  PO RESTARTU se systémový disk $SYSTEM_DISK přepíše instalací."
echo "   Ujistěte se, že na něm nemáte žádná důležitá data."
echo ""
echo "📂  Konfigurace byla uložena do: $CONFIG_FILE"
echo "   Pro opakované použití ji můžete načíst automaticky (příště se skript zeptá)."