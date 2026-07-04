#!/bin/bash
# =============================================================================
# proxmox-post-install.sh  –  Automatická konfigurace Proxmoxu po instalaci
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
error_exit() { echo -e "${RED}❌ CHYBA: $*${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}>>> $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }

# ---- Oprávnění ----
if [[ $EUID -ne 0 ]]; then
    error_exit "Spusťte jako root: sudo $0"
fi

# ---- Konfigurační proměnné (upravte dle potřeby) ----
# Repositáře
REPO_NO_SUB="deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription"
REPO_CEPH="deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription"

# Uživatelé (přidá uživatele admin s heslem a SSH klíčem)
ADMIN_USER="admin"
ADMIN_PASS="heslo123"           # změňte!
ADMIN_SSH_KEY="ssh-rsa AAA..."  # vložte váš veřejný klíč, nebo ponechte prázdné

# Disk pro Ceph (použije se /dev/sdb, /dev/sdc, ...) – nechte prázdné pro přeskočení
CEPH_DISKS=("/dev/sdb" "/dev/sdc")   # seznam disků pro OSD
CEPH_NETWORK="10.0.0.0/24"           # síť pro Ceph

# Stažení ISO (seznam URL)
ISO_LIST=(
    "https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso"
    "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.9.0-amd64-netinst.iso"
)

# Další nástroje
TOOLS="htop vim curl wget git net-tools fail2ban cockpit netdata ufw"

# ---- 1. Aktualizace repozitářů a odstranění enterprise ----
info "Aktualizace APT a odstranění enterprise repozitáře..."
sed -i 's/^deb.*enterprise.*/#&/' /etc/apt/sources.list.d/pve-enterprise.list || true
echo "$REPO_NO_SUB" > /etc/apt/sources.list.d/pve-no-subscription.list
echo "$REPO_CEPH" > /etc/apt/sources.list.d/ceph.list
apt update

# ---- 2. Upgrade systému a instalace nástrojů ----
info "Upgrade systému a instalace nástrojů..."
apt upgrade -y
apt install -y $TOOLS

# ---- 3. Konfigurace SSH ----
info "Nastavuji SSH..."
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart sshd

# ---- 4. Vytvoření administrátorského uživatele ----
if id "$ADMIN_USER" &>/dev/null; then
    warn "Uživatel $ADMIN_USER již existuje."
else
    info "Vytvářím uživatele $ADMIN_USER..."
    useradd -m -s /bin/bash "$ADMIN_USER"
    echo "$ADMIN_USER:$ADMIN_PASS" | chpasswd
    usermod -aG sudo "$ADMIN_USER"
    # Přidání SSH klíče
    if [[ -n "$ADMIN_SSH_KEY" ]]; then
        mkdir -p "/home/$ADMIN_USER/.ssh"
        echo "$ADMIN_SSH_KEY" > "/home/$ADMIN_USER/.ssh/authorized_keys"
        chown -R "$ADMIN_USER:" "/home/$ADMIN_USER/.ssh"
        chmod 700 "/home/$ADMIN_USER/.ssh"
        chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
    fi
fi

# ---- 5. Konfigurace firewallu (UFW) ----
info "Nastavuji UFW..."
ufw allow 22/tcp
ufw allow 8006/tcp   # Proxmox web
ufw allow 3306/tcp   # MySQL (příklad)
ufw --force enable

# ---- 6. Instalace a konfigurace fail2ban ----
systemctl enable fail2ban
systemctl start fail2ban

# ---- 7. Stažení ISO souborů do úložiště ----
ISO_DIR="/var/lib/vz/template/iso"
mkdir -p "$ISO_DIR"
for url in "${ISO_LIST[@]}"; do
    fname=$(basename "$url")
    if [[ ! -f "$ISO_DIR/$fname" ]]; then
        info "Stahuji $fname ..."
        wget -O "$ISO_DIR/$fname" "$url" || warn "Stažení $fname selhalo."
    else
        info "$fname již existuje."
    fi
done

# ---- 8. Konfigurace CephFS (pokud jsou definovány CEPH_DISKS) ----
if [[ ${#CEPH_DISKS[@]} -gt 0 ]]; then
    info "Instaluji Ceph a konfiguruji mon a OSD..."
    apt install -y ceph ceph-mon ceph-osd ceph-mgr ceph-mds

    # Inicializace clusteru (mon)
    MON_IP=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
    if [[ -z "$MON_IP" ]]; then
        warn "Nelze zjistit IP – Ceph konfigurace přeskočena."
    else
        ceph-authtool --create-keyring /etc/ceph/ceph.mon.keyring --gen-key -n mon. || true
        ceph-authtool --create-keyring /etc/ceph/ceph.client.admin.keyring --gen-key -n client.admin || true
        ceph-authtool /etc/ceph/ceph.client.admin.keyring --set-uid=0 --gen-key -n client.admin || true
        ceph-authtool /etc/ceph/ceph.mon.keyring --import-keyring /etc/ceph/ceph.client.admin.keyring || true

        # Vytvoření monmap
        monmaptool --create --add "$HOSTNAME" "$MON_IP" --fsid "$(uuidgen)" /etc/ceph/monmap || true

        # Spuštění monitoru
        ceph-mon --mkfs -i "$HOSTNAME" --monmap /etc/ceph/monmap --keyring /etc/ceph/ceph.mon.keyring || true
        systemctl enable ceph-mon@"$HOSTNAME"
        systemctl start ceph-mon@"$HOSTNAME"

        # OSD – přidání disků
        for disk in "${CEPH_DISKS[@]}"; do
            if [[ -b "$disk" ]]; then
                info "Přidávám OSD na $disk ..."
                ceph-volume lvm create --data "$disk" || warn "Selhalo přidání OSD na $disk"
            else
                warn "Disk $disk neexistuje – přeskočeno."
            fi
        done

        # Spuštění ceph-mgr
        systemctl enable ceph-mgr@"$HOSTNAME"
        systemctl start ceph-mgr@"$HOSTNAME"

        # Vytvoření CephFS (metadata a data pool)
        ceph osd pool create cephfs_metadata 64 64 || true
        ceph osd pool create cephfs_data 128 128 || true
        ceph fs new cephfs cephfs_metadata cephfs_data || true

        info "CephFS byl vytvořen. Stav clusteru:"
        ceph -s
    fi
else
    info "Ceph konfigurace přeskočena (nebyly zadány disky)."
fi

# ---- 9. Nastavení datacentrových předvoleb ----
info "Nastavuji výchozí předvolby datacentra (přes pvesh)..."
# Nastavení výchozího úložiště (local)
pvesh set /storage/local --content "images,iso,vztmpl,backup" || true

# Povolení HA (pokud je cluster)
if [[ -f /etc/pve/ha/crm.conf ]]; then
    pvesh set /cluster/ha --enabled 1 || true
fi

# Nastavení mail-to (pro notifikace)
pvesh set /datacenter/options --email-from "root@$HOSTNAME" || true

# Nastavení metric serveru (např. InfluxDB)
pvesh create /datacenter/metrics/server --id influx --server 10.0.0.10 --port 8089 || true

# Mapování prostředků (příklad – přidání NFS, ale vyžaduje existenci NFS serveru)
# pvesh create /storage/nfs --id nfs1 --path /mnt/nfs --server 192.168.1.10 --export /export

# Vytvoření složky pro zálohy (pokud neexistuje)
mkdir -p /var/lib/vz/dump
chown root:www-data /var/lib/vz/dump

# ---- 10. Závěrečné vyčištění a restart ----
info "Aktualizace GRUB a závěrečné úpravy..."
update-grub
apt autoremove -y

echo ""
echo "============================================================="
echo "   KONFIGURACE DOKONČENA"
echo "============================================================="
echo "✅ Repozitáře nastaveny, systém aktualizován"
echo "✅ Uživatel $ADMIN_USER vytvořen"
echo "✅ Firewall a fail2ban spuštěny"
echo "✅ ISO soubory staženy do $ISO_DIR"
if [[ ${#CEPH_DISKS[@]} -gt 0 ]]; then
    echo "✅ Ceph cluster inicializován (mon, osd, mgr, cephfs)"
fi
echo "✅ Datacentrové předvolby nastaveny"
echo ""
echo "➡️  Pro přístup k webovému rozhraní: https://$(hostname -I | awk '{print $1}'):8006"
echo "   Přihlašte se jako root s heslem, které jste zadali při instalaci."
echo ""
echo "📂  Skript lze znovu spustit pro doplnění konfigurace."
