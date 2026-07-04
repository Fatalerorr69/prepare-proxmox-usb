#!/bin/bash
# ======================================================================
# KOMPLETNÍ PŘÍPRAVA PRO AUTOMATICKOU INSTALACI PROXMOXu
# ======================================================================
# Tento skript:
#   - běží na LIVE systému (Ubuntu Live USB apod.)
#   - vyžádá všechny potřebné údaje (s validací)
#   - stáhne Proxmox ISO, vytvoří answer.toml a automatické ISO
#   - zapíše ISO na USB flash disk (s kontrolou)
#   - vymaže datové disky (volitelně) a systémový disk (po potvrzení)
#   - provede S.M.A.R.T. kontrolu
#   - uloží konfiguraci pro opakované použití
#
# VAROVÁNÍ: Všechny operace jsou NEVRATNÉ – před spuštěním si zazálohujte data!
# ======================================================================

set -euo pipefail

# ---- Barvy a pomocné funkce ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

error_exit() {
    echo -e "${RED}❌ CHYBA: $*${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}>>> $*${NC}"
}

warn() {
    echo -e "${YELLOW}⚠️  $*${NC}"
}

# Robustní potvrzení – akceptuje ANO, A, YES, Y
confirm() {
    local prompt="$1"
    local answer
    while true; do
        read -p "$prompt (pro pokračování napište 'ANO'): " answer
        answer=$(echo "$answer" | tr -d "'\"" | xargs | tr '[:lower:]' '[:upper:]')
        if [[ "$answer" == "ANO" || "$answer" == "A" || "$answer" == "YES" || "$answer" == "Y" ]]; then
            return 0
        else
            echo "Odpověď nebyla rozpoznána. Zadejte 'ANO' pro pokračování."
        fi
    done
}

# Normalizace cesty k disku (doplní /dev/)
normalize_disk() {
    local disk="$1"
    if [[ "$disk" != /dev/* ]]; then
        disk="/dev/$disk"
    fi
    echo "$disk"
}

disk_exists() {
    [[ -b "$1" ]]
}

is_mounted() {
    mount | grep -q "^$1 "
}

# Zjistí, zda dva disky ukazují na stejné fyzické zařízení
is_same_disk() {
    local dev1=$(readlink -f "$1")
    local dev2=$(readlink -f "$2")
    [[ "$dev1" == "$dev2" ]]
}

# ---- Globální nastavení ----
WORK_DIR="/root/proxmox-automation"
ISO_URL="https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso"
CONFIG_FILE="$WORK_DIR/config.cfg"

# Povolené hodnoty pro klávesnici (podle oficiálního seznamu)
VALID_KEYBOARDS=("de" "de-ch" "dk" "en-gb" "en-us" "es" "fi" "fr" "fr-be" "fr-ca" "fr-ch" "hu" "is" "it" "jp" "lt" "mk" "nl" "no" "pl" "pt" "pt-br" "se" "si" "tr")

# ---- 1. Kontrola oprávnění ----
if [[ $EUID -ne 0 ]]; then
    error_exit "Tento skript musí být spuštěn jako root. Použijte: sudo $0"
fi

# ---- 2. Kontrola live prostředí ----
echo "============================================================="
echo "   PŘÍPRAVA PRO AUTOMATICKOU INSTALACI PROXMOXu"
echo "============================================================="
echo ""
echo "⚠️  Skript MUSÍ být spuštěn z LIVE SYSTÉMU (např. Ubuntu Live USB),"
echo "   aby bylo možné vymazat systémový disk."
echo ""
read -p "Jste v live prostředí? (a/n): " live_ok
live_ok=$(echo "$live_ok" | tr '[:upper:]' '[:lower:]')
if [[ "$live_ok" != "a" && "$live_ok" != "ano" && "$live_ok" != "y" && "$live_ok" != "yes" ]]; then
    error_exit "Skript byl ukončen – není spuštěn v live systému."
fi

# ---- 3. Instalace závislostí ----
info "Instaluji potřebné balíčky..."
apt update || error_exit "Aktualizace repozitářů selhala."
apt install -y wget xorriso smartmontools proxmox-auto-install-assistant || {
    error_exit "Instalace závislostí selhala. Zkuste ručně: apt install wget xorriso smartmontools proxmox-auto-install-assistant"
}

if ! command -v proxmox-auto-install-assistant &> /dev/null; then
    error_exit "Nástroj 'proxmox-auto-install-assistant' nebyl nalezen."
fi

# ---- 4. Pracovní adresář ----
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ---- 5. Pokus o načtení existující konfigurace ----
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Nalezena existující konfigurace v $CONFIG_FILE"
    read -p "Chcete ji použít a přeskočit dotazování? (a/n): " use_config
    use_config=$(echo "$use_config" | tr '[:upper:]' '[:lower:]')
    if [[ "$use_config" == "a" || "$use_config" == "ano" || "$use_config" == "y" || "$use_config" == "yes" ]]; then
        source "$CONFIG_FILE"
        info "Konfigurace načtena."
        USE_EXISTING=1
    else
        USE_EXISTING=0
    fi
else
    USE_EXISTING=0
fi

# ---- 6. Interaktivní dotazování (pokud nebyla načtena konfigurace) ----
if [[ $USE_EXISTING -eq 0 ]]; then
    echo ""
    info "Zadejte prosím požadované informace pro instalaci Proxmoxu."

    # Zobrazení disků
    echo ""
    echo "Seznam všech disků v systému:"
    lsblk -o NAME,SIZE,MODEL,MOUNTPOINT
    echo ""

    # Systémový disk
    read -p "Zadejte SYSTÉMOVÝ disk (např. /dev/nvme0n1, nvme0n1, /dev/sda): " SYSTEM_DISK_RAW
    SYSTEM_DISK=$(normalize_disk "$SYSTEM_DISK_RAW")
    disk_exists "$SYSTEM_DISK" || error_exit "Disk $SYSTEM_DISK neexistuje."
    if is_mounted "$SYSTEM_DISK"; then
        warn "Disk $SYSTEM_DISK je připojen! Pokračování může poškodit běžící systém."
        confirm "Opravdu chcete pokračovat?" || error_exit "Ukončeno."
    fi

    # Datové disky
    read -p "Zadejte DATOVÉ disky k vymazání (oddělené mezerou, např. sdb sdc), nebo nechte prázdné: " data_input
    DATA_DISKS=()
    if [[ -n "$data_input" ]]; then
        for d in $data_input; do
            d=$(normalize_disk "$d")
            if disk_exists "$d"; then
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
    TIMEZONE="${TIMEZONE:-Europe/Prague}"

    # Výběr klávesnice s validací
    echo "Dostupné klávesnice: ${VALID_KEYBOARDS[*]}"
    read -p "Zadejte kód klávesnice (výchozí 'en-us'): " KEYBOARD_INPUT
    if [[ -n "$KEYBOARD_INPUT" ]]; then
        found=0
        for kb in "${VALID_KEYBOARDS[@]}"; do
            if [[ "$KEYBOARD_INPUT" == "$kb" ]]; then
                found=1
                KEYBOARD="$kb"
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            warn "Hodnota '$KEYBOARD_INPUT' není povolena – používám 'en-us'."
            KEYBOARD="en-us"
        fi
    else
        KEYBOARD="en-us"
    fi
    echo "Použita klávesnice: $KEYBOARD"

    read -p "Kód země (např. cz, de, us): " COUNTRY
    COUNTRY="${COUNTRY:-cz}"

    # Síť
    read -p "Síť – DHCP (d) nebo statická IP (s)? " net_choice
    net_choice=$(echo "$net_choice" | tr '[:upper:]' '[:lower:]')
    if [[ "$net_choice" == "d" || "$net_choice" == "dhcp" ]]; then
        NET_SOURCE="dhcp"
    else
        NET_SOURCE="static"
        read -p "IP adresa s prefixem (např. 192.168.1.100/24): " IP_CIDR
        read -p "Brána (např. 192.168.1.1): " GATEWAY
        read -p "DNS server (např. 8.8.8.8): " DNS
    fi

    # Souborový systém
    read -p "Souborový systém pro systém (ext4 / xfs / zfs) [ext4]: " FILESYSTEM_INPUT
    if [[ -n "$FILESYSTEM_INPUT" ]]; then
        FILESYSTEM="$FILESYSTEM_INPUT"
    else
        FILESYSTEM="ext4"
    fi
    if [[ ! "$FILESYSTEM" =~ ^(ext4|xfs|zfs)$ ]]; then
        warn "Neznámý souborový systém – používám ext4."
        FILESYSTEM="ext4"
    fi

    # Zápis na USB?
    read -p "Chcete vytvořené ISO zapsat na USB flash disk? (a/n): " write_usb
    write_usb=$(echo "$write_usb" | tr '[:upper:]' '[:lower:]')
    if [[ "$write_usb" == "a" || "$write_usb" == "ano" || "$write_usb" == "y" || "$write_usb" == "yes" ]]; then
        write_usb="a"
    else
        write_usb="n"
    fi

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
write_usb="$write_usb"
EOF
    info "Konfigurace uložena do $CONFIG_FILE"
fi

# ---- 7. Stažení Proxmox ISO ----
ISO_FILE="$WORK_DIR/$(basename "$ISO_URL")"
if [[ -f "$ISO_FILE" ]]; then
    info "ISO již existuje: $ISO_FILE"
else
    info "Stahuji Proxmox ISO z $ISO_URL ..."
    wget -O "$ISO_FILE" "$ISO_URL" || error_exit "Stažení ISO selhalo."
fi

# ---- 8. Vytvoření answer.toml ----
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

# ---- 9. Příprava automatického ISO ----
CUSTOM_ISO="$WORK_DIR/proxmox-automated.iso"
info "Vytvářím vlastní ISO s automatickou instalací..."
proxmox-auto-install-assistant prepare-iso "$ISO_FILE" \
    --fetch-from iso \
    --answer-file "$ANSWER_FILE" \
    --output "$CUSTOM_ISO" || error_exit "Příprava ISO selhala. Zkontrolujte answer.toml."

info "Vlastní ISO vytvořeno: $CUSTOM_ISO"

# ---- 10. Zápis na USB (volitelně) ----
if [[ "$write_usb" == "a" ]]; then
    info "Detekuji USB flash disky ≥4 GB..."
    USB_DEVICES=()
    while read -r dev; do
        if [[ -b "$dev" ]] && udevadm info --query=property --name="$dev" 2>/dev/null | grep -q "ID_BUS=usb"; then
            SIZE_GB=$(blockdev --getsize64 "$dev" | awk '{print int($1/1024/1024/1024)}')
            if [[ $SIZE_GB -ge 4 ]]; then
                USB_DEVICES+=("$dev:$SIZE_GB")
            fi
        fi
    done < <(lsblk -lno NAME | grep -E '^sd[a-z]$|^nvme[0-9]n[0-9]$' | sed 's/^/\/dev\//')

    if [[ ${#USB_DEVICES[@]} -eq 0 ]]; then
        error_exit "Nebyl nalezen žádný USB disk ≥4 GB."
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
    USB_DEVICE=$(echo "${USB_DEVICES[$((choice-1))]}" | cut -d: -f1)
    info "Vybraný USB disk: $USB_DEVICE"

    # Kontrola, že USB není systémový disk
    if is_same_disk "$USB_DEVICE" "$SYSTEM_DISK"; then
        error_exit "USB zařízení je stejné jako systémový disk! Zápis by smazal systém. Opravte volbu."
    fi

    # Odpojení oddílů
    for part in $(lsblk -lno NAME "$USB_DEVICE" | grep -E "^${USB_DEVICE##*/}[0-9]" | sed 's/^/\/dev\//'); do
        mount | grep -q "$part" && umount "$part" 2>/dev/null || true
    done

    confirm "Tímto smažete VŠECHNA data na $USB_DEVICE. Pokračovat?" || error_exit "Zápis zrušen."
    dd bs=4M conv=fdatasync if="$CUSTOM_ISO" of="$USB_DEVICE" status=progress || error_exit "Zápis na USB selhal."
    sync
    info "✅ ISO zapsáno na USB: $USB_DEVICE"
fi

# ---- 11. Vymazání datových disků ----
if [[ ${#DATA_DISKS[@]} -gt 0 ]]; then
    echo ""
    warn "BYLY VYBRÁNY DATOVÉ DISKY K VYMAZÁNÍ: ${DATA_DISKS[*]}"
    confirm "Opravdu chcete TRVALE SMAZAT VŠECHNA DATA na těchto discích?" || {
        warn "Vymazání datových disků přeskočeno."
        DATA_DISKS=()
    }

    for disk in "${DATA_DISKS[@]}"; do
        info "Mažu disk: $disk"
        wipefs -a "$disk" || warn "wipefs selhalo, pokračuji..."
        dd if=/dev/zero of="$disk" bs=1M count=200 conv=fdatasync status=progress
        parted -s "$disk" mklabel gpt || warn "parted mklabel selhalo, pokračuji..."
        parted -s "$disk" mkpart primary 0% 100% || warn "vytvoření oddílu selhalo, pokračuji..."
        mkfs.ext4 -F "${disk}1" || warn "formátování selhalo, pokračuji..."
        info "✅ Disk $disk vymazán a naformátován na ext4."
    done
else
    info "Nebyly vybrány žádné datové disky k vymazání."
fi

# ---- 12. Vymazání systémového disku ----
echo ""
warn "PŘIPRAVUJI SE NA VYMAZÁNÍ SYSTÉMOVÉHO DISKU: $SYSTEM_DISK"
echo "⚠️  TENTO KROK SMAŽE VŠECHNA DATA VČETNĚ BOOT SEKTORU!"
confirm "Jste si naprosto jisti, že chcete vymazat $SYSTEM_DISK?" || error_exit "Vymazání systémového disku zrušeno."

info "Mažu $SYSTEM_DISK ..."
wipefs -a "$SYSTEM_DISK" || warn "wipefs selhalo, pokračuji..."
dd if=/dev/zero of="$SYSTEM_DISK" bs=1M count=200 conv=fdatasync status=progress
info "✅ Systemový disk $SYSTEM_DISK vymazán."

# ---- 13. S.M.A.R.T. kontrola ----
echo ""
info "Provádím S.M.A.R.T. kontrolu všech disků..."
for disk in /dev/sd? /dev/nvme?n?; do
    [[ -b "$disk" ]] || continue
    echo "-------------------------------------------------------------"
    echo "Disk: $disk"
    smartctl -i "$disk" | grep -E "Device Model|Serial Number|Firmware Version|SMART support|User Capacity" || echo "  (informace nedostupné)"
    if smartctl -H "$disk" &>/dev/null; then
        STATUS=$(smartctl -H "$disk" | grep "SMART overall-health" | awk '{print $6}')
        if [[ "$STATUS" == "PASSED" ]]; then
            echo "  S.M.A.R.T. stav: ✅ PASSED"
        else
            echo "  S.M.A.R.T. stav: ❌ $STATUS (pozor!)"
        fi
    else
        echo "  S.M.A.R.T. není podporován nebo je zakázán."
    fi
    smartctl -A "$disk" 2>/dev/null | grep -E "Temperature_Celsius|Wear_Leveling_Count|Reallocated_Sector|Current_Pending_Sector" || true
done

# ---- 14. Závěrečné informace ----
echo ""
echo "============================================================="
echo "   HOTOVO – PŘIPRAVENO K INSTALACI"
echo "============================================================="
echo ""
echo "✅ Vlastní ISO: $CUSTOM_ISO"
if [[ "$write_usb" == "a" ]]; then
    echo "✅ USB: $USB_DEVICE"
fi
echo "✅ Systémový disk $SYSTEM_DISK byl vymazán."
echo "✅ Datové disky byly vymazány (pokud byly vybrány)."
echo "✅ S.M.A.R.T. kontrola provedena."
echo ""
echo "➡️  Restartujte server a nabootujte z připraveného USB (nebo ISO)."
echo "   Instalace Proxmoxu proběhne zcela automaticky."
echo ""
echo "⚠️  Po restartu se přihlaste s root heslem, které jste zadali."
echo "📂  Konfigurace uložena v $CONFIG_FILE – při příštím spuštění ji lze načíst."
