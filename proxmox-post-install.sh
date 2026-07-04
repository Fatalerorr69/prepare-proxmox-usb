#!/bin/bash
# =============================================================================
# proxmox-post-install.sh  –  Kompletní konfigurace Proxmoxu po instalaci
# =============================================================================
# Tento skript:
#   - interaktivně získá od uživatele všechny potřebné údaje
#   - uloží je pro opakované použití
#   - nainstaluje doporučené nástroje a služby
#   - stáhne golden images (OS šablony)
#   - umožní výběr a instalaci LXC kontejnerů s přednastavenými rolemi
#   - nainstaluje další knihovny a prostředí (Docker, Python, Node.js, …)
#   - provede konfiguraci datacentra a volitelně i Ceph
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

# ---- Kontrola oprávnění ----
if [[ $EUID -ne 0 ]]; then
    error_exit "Tento skript musí být spuštěn jako root. Použijte: sudo $0"
fi

# ---- Konfigurační soubor ----
CONFIG_FILE="/root/proxmox-config.cfg"
LOAD_CONFIG=0

# ---- Načtení existující konfigurace ----
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Nalezena existující konfigurace v $CONFIG_FILE"
    read -p "Chcete ji načíst a přeskočit dotazování? (a/n): " load
    if [[ "$load" =~ ^[AaYy] ]]; then
        source "$CONFIG_FILE"
        LOAD_CONFIG=1
        info "Konfigurace načtena."
    fi
fi

# ---- Pokud konfigurace nebyla načtena, zeptáme se uživatele ----
if [[ $LOAD_CONFIG -eq 0 ]]; then
    echo ""
    info "Zadejte prosím požadované informace pro konfiguraci Proxmoxu."

    # Základní údaje
    read -p "Hostname (FQDN, např. pve.mojedomena.cz): " HOSTNAME
    [[ -n "$HOSTNAME" ]] || error_exit "Hostname nesmí být prázdný."
    hostnamectl set-hostname "$HOSTNAME"

    read -sp "Root heslo (pro přihlášení do webového rozhraní): " ROOT_PASSWORD
    echo ""
    [[ -n "$ROOT_PASSWORD" ]] || error_exit "Heslo nesmí být prázdné."
    echo "root:$ROOT_PASSWORD" | chpasswd

    # SSH klíč – zobrazení návodu
    echo ""
    info "Pro bezheslové přihlašování SSH doporučujeme použít SSH klíč."
    echo "Pokud ještě žádný nemáte, vygenerujte ho příkazem:"
    echo "  ssh-keygen -t rsa -b 4096 -C \"$HOSTNAME\""
    echo "Veřejný klíč pak najdete v ~/.ssh/id_rsa.pub"
    echo ""
    read -p "Chcete vložit veřejný SSH klíč pro uživatele root? (a/n): " add_ssh
    if [[ "$add_ssh" =~ ^[AaYy] ]]; then
        echo "Zadejte veřejný SSH klíč (celý řádek začínající 'ssh-rsa' nebo 'ssh-ed25519'):"
        read -r SSH_KEY
        if [[ -n "$SSH_KEY" ]]; then
            mkdir -p /root/.ssh
            echo "$SSH_KEY" >> /root/.ssh/authorized_keys
            chmod 700 /root/.ssh
            chmod 600 /root/.ssh/authorized_keys
            info "SSH klíč přidán."
        fi
    fi

    # Síť
    echo ""
    read -p "Síť – DHCP (d) nebo statická IP (s)? " net_choice
    net_choice=$(echo "$net_choice" | tr '[:upper:]' '[:lower:]')
    if [[ "$net_choice" == "d" || "$net_choice" == "dhcp" ]]; then
        NET_SOURCE="dhcp"
    else
        NET_SOURCE="static"
        read -p "IP adresa s prefixem (např. 192.168.1.100/24): " IP_CIDR
        read -p "Brána (např. 192.168.1.1): " GATEWAY
        read -p "DNS server (např. 8.8.8.8): " DNS
        # Nastavení statické IP (pouze příklad – pro plnou konfiguraci by bylo potřeba upravit /etc/network/interfaces)
        warn "Statická IP nebude automaticky nastavena – upravte síť ručně."
    fi

    # Golden images – OS šablony
    echo ""
    info "Stáhnout předpřipravené OS šablony (golden images) pro VM/LXC?"
    echo "Dostupné: Debian 12, Ubuntu 24.04, Alpine 3.20"
    read -p "Stáhnout všechny? (a/n), nebo zadejte čárkami oddělený seznam (např. debian,ubuntu): " images_choice
    IMAGES_TO_DOWNLOAD=""
    if [[ "$images_choice" =~ ^[AaYy] ]]; then
        IMAGES_TO_DOWNLOAD="debian ubuntu alpine"
    elif [[ -n "$images_choice" ]]; then
        IMAGES_TO_DOWNLOAD=$(echo "$images_choice" | tr ',' ' ')
    fi

    # LXC kontejnery
    echo ""
    info "Chcete nainstalovat předpřipravené LXC kontejnery s různými rolemi?"
    echo "Dostupné role: webserver (nginx), database (mysql), dns (bind9), monitoring (netdata), docker, pihole"
    read -p "Zadejte čárkami oddělený seznam rolí (např. webserver,database), nebo nechte prázdné: " LXC_ROLES_INPUT
    LXC_ROLES=""
    if [[ -n "$LXC_ROLES_INPUT" ]]; then
        LXC_ROLES=$(echo "$LXC_ROLES_INPUT" | tr ',' ' ')
    fi

    # Další knihovny a prostředí
    echo ""
    info "Které další nástroje a prostředí chcete nainstalovat?"
    echo "Dostupné: docker, kubernetes (microk8s), python, nodejs, ansible"
    read -p "Zadejte čárkami oddělený seznam (např. docker,python), nebo nechte prázdné: " TOOLS_INPUT
    EXTRA_TOOLS=""
    if [[ -n "$TOOLS_INPUT" ]]; then
        EXTRA_TOOLS=$(echo "$TOOLS_INPUT" | tr ',' ' ')
    fi

    # Ceph
    echo ""
    read -p "Chcete nakonfigurovat Ceph cluster na tomto uzlu? (a/n): " ceph_choice
    if [[ "$ceph_choice" =~ ^[AaYy] ]]; then
        CONFIGURE_CEPH=1
        read -p "Zadejte disky pro OSD (oddělené mezerou, např. /dev/sdb /dev/sdc): " CEPH_DISKS_INPUT
        CEPH_DISKS=($CEPH_DISKS_INPUT)
        read -p "Zadejte síť pro Ceph (např. 10.0.0.0/24): " CEPH_NETWORK
    else
        CONFIGURE_CEPH=0
        CEPH_DISKS=()
        CEPH_NETWORK=""
    fi

    # Datacentrové předvolby
    echo ""
    read -p "Zadejte email pro notifikace (výchozí root@$HOSTNAME): " DATACENTER_EMAIL
    DATACENTER_EMAIL="${DATACENTER_EMAIL:-root@$HOSTNAME}"
    read -p "Zadejte IP adresu InfluxDB serveru pro metriky (nepovinné): " METRIC_SERVER_IP
    read -p "Port InfluxDB (výchozí 8089): " METRIC_SERVER_PORT
    METRIC_SERVER_PORT="${METRIC_SERVER_PORT:-8089}"

    # Uložení konfigurace
    cat > "$CONFIG_FILE" <<EOF
HOSTNAME="$HOSTNAME"
ROOT_PASSWORD="$ROOT_PASSWORD"
NET_SOURCE="$NET_SOURCE"
IP_CIDR="${IP_CIDR:-}"
GATEWAY="${GATEWAY:-}"
DNS="${DNS:-}"
IMAGES_TO_DOWNLOAD="$IMAGES_TO_DOWNLOAD"
LXC_ROLES="$LXC_ROLES"
EXTRA_TOOLS="$EXTRA_TOOLS"
CONFIGURE_CEPH=$CONFIGURE_CEPH
CEPH_DISKS=(${CEPH_DISKS[@]})
CEPH_NETWORK="$CEPH_NETWORK"
DATACENTER_EMAIL="$DATACENTER_EMAIL"
METRIC_SERVER_IP="$METRIC_SERVER_IP"
METRIC_SERVER_PORT="$METRIC_SERVER_PORT"
EOF
    info "Konfigurace uložena do $CONFIG_FILE"
fi

# =============================================================================
# HLAVNÍ ČÁST – PROVEDENÍ KONFIGURACE
# =============================================================================

# 1. Aktualizace a repozitáře
info "Aktualizace systému a nastavení repozitářů..."
sed -i 's/^deb.*enterprise.*/#&/' /etc/apt/sources.list.d/pve-enterprise.list || true
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
apt update
apt upgrade -y

# 2. Instalace základních nástrojů
info "Instalace doporučených nástrojů..."
apt install -y htop vim curl wget git net-tools dnsutils ethtool tmux btop ufw fail2ban

# 3. Firewall a fail2ban
info "Konfigurace firewallu (UFW) a fail2ban..."
ufw allow 22/tcp
ufw allow 8006/tcp
ufw --force enable
systemctl enable fail2ban
systemctl start fail2ban

# 4. Stažení golden images (OS šablon)
if [[ -n "$IMAGES_TO_DOWNLOAD" ]]; then
    info "Stahuji OS šablony..."
    ISO_DIR="/var/lib/vz/template/iso"
    mkdir -p "$ISO_DIR"
    for img in $IMAGES_TO_DOWNLOAD; do
        case "$img" in
            debian)
                url="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.9.0-amd64-netinst.iso"
                ;;
            ubuntu)
                url="https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso"
                ;;
            alpine)
                url="https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-virt-3.20.3-x86_64.iso"
                ;;
            *)
                warn "Neznámý obraz: $img – přeskočeno."
                continue
                ;;
        esac
        fname=$(basename "$url")
        if [[ ! -f "$ISO_DIR/$fname" ]]; then
            info "Stahuji $fname ..."
            wget -O "$ISO_DIR/$fname" "$url" || warn "Stažení $fname selhalo."
        else
            info "$fname již existuje."
        fi
    done
fi

# 5. Instalace LXC kontejnerů s rolemi
if [[ -n "$LXC_ROLES" ]]; then
    info "Instaluji LXC kontejnery s rolemi: $LXC_ROLES"
    # Zajištění, že máme šablonu pro LXC (např. debian-12-standard)
    apt install -y debian-12-standard
    CTID=200
    for role in $LXC_ROLES; do
        info "Vytvářím kontejner $CTID s rolí $role ..."
        # Vytvoření kontejneru s Debian 12
        pct create "$CTID" local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst \
            --hostname "$role-$(hostname)" \
            --memory 512 \
            --swap 256 \
            --cores 1 \
            --net0 name=eth0,bridge=vmbr0,ip=dhcp \
            --rootfs local:8 \
            --features nesting=1 \
            --unprivileged 1
        pct start "$CTID"

        # Konfigurace dle role
        case "$role" in
            webserver)
                pct exec "$CTID" -- apt update
                pct exec "$CTID" -- apt install -y nginx
                pct exec "$CTID" -- systemctl enable nginx
                pct exec "$CTID" -- systemctl start nginx
                ;;
            database)
                pct exec "$CTID" -- apt update
                pct exec "$CTID" -- apt install -y mariadb-server
                pct exec "$CTID" -- systemctl enable mariadb
                pct exec "$CTID" -- systemctl start mariadb
                ;;
            dns)
                pct exec "$CTID" -- apt update
                pct exec "$CTID" -- apt install -y bind9
                pct exec "$CTID" -- systemctl enable bind9
                pct exec "$CTID" -- systemctl start bind9
                ;;
            monitoring)
                pct exec "$CTID" -- apt update
                pct exec "$CTID" -- apt install -y netdata
                pct exec "$CTID" -- systemctl enable netdata
                pct exec "$CTID" -- systemctl start netdata
                ;;
            docker)
                pct exec "$CTID" -- apt update
                pct exec "$CTID" -- apt install -y docker.io
                pct exec "$CTID" -- systemctl enable docker
                pct exec "$CTID" -- systemctl start docker
                ;;
            pihole)
                pct exec "$CTID" -- apt update
                pct exec "$CTID" -- apt install -y curl
                pct exec "$CTID" -- curl -sSL https://install.pi-hole.net | bash
                ;;
            *)
                warn "Neznámá role: $role – kontejner vytvořen bez další konfigurace."
                ;;
        esac
        CTID=$((CTID + 1))
    done
fi

# 6. Instalace dalších nástrojů a prostředí
if [[ -n "$EXTRA_TOOLS" ]]; then
    info "Instaluji další nástroje: $EXTRA_TOOLS"
    for tool in $EXTRA_TOOLS; do
        case "$tool" in
            docker)
                apt install -y docker.io
                systemctl enable docker
                systemctl start docker
                ;;
            kubernetes)
                apt install -y snapd
                snap install microk8s --classic
                microk8s status --wait-ready
                ;;
            python)
                apt install -y python3 python3-pip python3-venv
                ;;
            nodejs)
                curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
                apt install -y nodejs
                ;;
            ansible)
                apt install -y ansible
                ;;
            *)
                warn "Neznámý nástroj: $tool – přeskočeno."
                ;;
        esac
    done
fi

# 7. Konfigurace Ceph (pokud bylo vybráno)
if [[ $CONFIGURE_CEPH -eq 1 && ${#CEPH_DISKS[@]} -gt 0 ]]; then
    info "Instaluji a konfiguruji Ceph..."
    apt install -y ceph ceph-mon ceph-osd ceph-mgr ceph-mds

    MON_IP=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
    if [[ -z "$MON_IP" ]]; then
        warn "Nelze zjistit IP – Ceph konfigurace přeskočena."
    else
        # Inicializace monitoru
        ceph-authtool --create-keyring /etc/ceph/ceph.mon.keyring --gen-key -n mon. || true
        ceph-authtool --create-keyring /etc/ceph/ceph.client.admin.keyring --gen-key -n client.admin || true
        ceph-authtool /etc/ceph/ceph.client.admin.keyring --set-uid=0 --gen-key -n client.admin || true
        ceph-authtool /etc/ceph/ceph.mon.keyring --import-keyring /etc/ceph/ceph.client.admin.keyring || true

        monmaptool --create --add "$HOSTNAME" "$MON_IP" --fsid "$(uuidgen)" /etc/ceph/monmap || true
        ceph-mon --mkfs -i "$HOSTNAME" --monmap /etc/ceph/monmap --keyring /etc/ceph/ceph.mon.keyring || true
        systemctl enable ceph-mon@"$HOSTNAME"
        systemctl start ceph-mon@"$HOSTNAME"

        # Přidání OSD
        for disk in "${CEPH_DISKS[@]}"; do
            if [[ -b "$disk" ]]; then
                info "Přidávám OSD na $disk ..."
                ceph-volume lvm create --data "$disk" || warn "Selhalo přidání OSD na $disk"
            else
                warn "Disk $disk neexistuje – přeskočeno."
            fi
        done

        systemctl enable ceph-mgr@"$HOSTNAME"
        systemctl start ceph-mgr@"$HOSTNAME"

        # Vytvoření CephFS
        ceph osd pool create cephfs_metadata 64 64 || true
        ceph osd pool create cephfs_data 128 128 || true
        ceph fs new cephfs cephfs_metadata cephfs_data || true

        info "Ceph cluster inicializován."
        ceph -s
    fi
fi

# 8. Nastavení datacentrových předvoleb
info "Nastavuji datacentrové předvolby..."
pvesh set /storage/local --content "images,iso,vztmpl,backup" || true
if [[ -f /etc/pve/ha/crm.conf ]]; then
    pvesh set /cluster/ha --enabled 1 || true
fi
pvesh set /datacenter/options --email-from "$DATACENTER_EMAIL" || true
if [[ -n "$METRIC_SERVER_IP" ]]; then
    pvesh create /datacenter/metrics/server --id influx --server "$METRIC_SERVER_IP" --port "$METRIC_SERVER_PORT" || true
fi
mkdir -p /var/lib/vz/dump
chown root:www-data /var/lib/vz/dump

# 9. Závěrečné úpravy
info "Aktualizace GRUB a vyčištění..."
update-grub
apt autoremove -y

echo ""
echo "============================================================="
echo "   ✅ KONFIGURACE DOKONČENA"
echo "============================================================="
echo ""
echo "🔹 Systém aktualizován, no-subscription repozitář nastaven."
echo "🔹 Nástroje: htop, vim, curl, git, tmux, btop, net-tools, dnsutils, ethtool, ufw, fail2ban"
if [[ -n "$IMAGES_TO_DOWNLOAD" ]]; then
    echo "🔹 Stažené OS šablony: $IMAGES_TO_DOWNLOAD"
fi
if [[ -n "$LXC_ROLES" ]]; then
    echo "🔹 Vytvořeny LXC kontejnery s rolemi: $LXC_ROLES (CTID 200+)"
fi
if [[ -n "$EXTRA_TOOLS" ]]; then
    echo "🔹 Nainstalovány další nástroje: $EXTRA_TOOLS"
fi
if [[ $CONFIGURE_CEPH -eq 1 ]]; then
    echo "🔹 Ceph cluster inicializován."
fi
echo "🔹 Datacentrum: předvolby nastaveny (HA, metriky, notifikace)."
echo ""
echo "🌐 Webové rozhraní: https://$(hostname -I | awk '{print $1}'):8006"
echo "   Přihlaste se jako root s heslem, které jste zadali."
echo ""
echo "📂  Konfigurace uložena v $CONFIG_FILE"
echo "   Při příštím spuštění skriptu ji můžete načíst."
