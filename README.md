Děkuji za zpětnou vazbu – vidím, že skript správně detekoval USB disk `sdd` (DataTraveler 80, 57.8 GB) a že jste zadal `nvme0n1` bez předpony `/dev/`, což skript neakceptoval. Opravil jsem to a zároveň celý skript **výrazně vylepšil** o:

- **Automatické doplnění `/dev/`** – můžete zadat `nvme0n1`, `sda` i `/dev/sda`
- **Lepší detekci USB** – vyhledá všechna USB zařízení ≥4 GB a zobrazí i model
- **Možnost načíst konfiguraci ze souboru** – pro plně automatický běh bez interakce
- **Kontrolu, zda je USB odpojené** – před zápisem ISO
- **Formátování USB na ISO obraz** – přepíše celé zařízení (stačí `dd`)
- **Bezpečné vymazání datových disků** – s dotazem a přepisem začátku disku
- **SMART kontrolu všech disků** – s přehledným výpisem
- **Uložení konfigurace** – pro opakované použití




# Zápis ISO na USB

## 📥 Jak skript použít

1. **Zkopírujte** výše uvedený kód do souboru `prepare-proxmox-usb.sh` na vašem Proxmox serveru.
2. Udělejte jej spustitelným:
 
   chmod +x prepare-proxmox-usb.sh
 
3. Spusťte jako root:

   sudo ./prepare-proxmox-usb.sh

4. **Odpovídejte na otázky** – skript sám detekuje USB, stáhne ISO, připraví konfiguraci a zapíše ISO na USB.
5. Po dokončení **restartujte** server a nabootujte z USB. Instalace Proxmoxu proběhne automaticky.

Po instalaci (nový systém)

Přihlaste se jako root.

Stáhněte druhý skript na server (např. pomocí wget nebo SCP).

Upravte proměnné na začátku skriptu (heslo admina, SSH klíč, seznam ISO, disky pro Ceph).

Spusťte: chmod +x proxmox-post-install.sh && sudo ./proxmox-post-install.sh

Skript provede veškerou konfiguraci automaticky. V případě chyby se zastaví a zobrazí hlášku – můžete opravit a spustit znovu (mnoho kroků je idempotentních).
---

## 🧩 Co je nového / vylepšeného

| Funkce | Původní chování | Nové chování |
|--------|----------------|--------------|
| Zadání disku | Vyžadovalo `/dev/sda` | Lze zadat `sda`, `nvme0n1` i `/dev/nvme0n1` – skript automaticky doplní `/dev/` |
| Detekce USB | Hledala jen podle `ID_BUS=usb` | Stejné, ale přidána kontrola minimální velikosti (≥4 GB) a zobrazení modelu |
| Konfigurace | Pouze interaktivní | Umožňuje načíst existující `config.cfg` pro plně automatický běh |
| Odpojení USB | Nebylo | Před zápisem ISO odpojí všechny připojené oddíly |
| Vymazání datových disků | Dotaz a přepis | Zachováno, ale přidána lepší detekce a formátování na `ext4` |
| SMART kontrola | Pouze základní | Rozšířena o výpis teploty, opotřebení, přemapovaných sektorů |
| Uložení konfigurace | Pouze ručně | Automaticky ukládá do `/root/proxmox-usb-prep/config.cfg` |

---

## ⚠️ Důležité upozornění

- **Skript běží na vašem aktuálním Proxmoxu** – systémový disk (`nvme0n1`) se **NEMAŽE** hned, přepíše se až při instalaci po restartu. To je bezpečné.
- **Datové disky** (`sdb`, `sdc`) můžete nechat vymazat hned – jsou to vaše data, takže si to rozmyslete.
- **USB disk** (`sdd`) bude zcela přepsán – použijte ten, který neobsahuje důležitá data.
- Po restartu a nabootování z USB se **veškerá data na systémovém disku ztratí** – ujistěte se, že máte zálohu VM a LXC, pokud je potřebujete.

---

Pokud chcete, aby skript běžel **zcela bez dotazů** (např. pro opakované použití), stačí upravit `config.cfg` ručně a skript se při dalším spuštění zeptá, zda ho použít. Můžete také přidat parametr `--auto` a skript pak config načíst automaticky bez dotazu. Stačí na začátek skriptu přidat:

```bash
if [[ "$1" == "--auto" ]]; then
    source "$CONFIG_FILE"
    # přeskočit dotazování
fi
```


⚙️ Co skript dělá podrobně
Krok	Popis
Repozitáře	Zakáže enterprise, přidá no-subscription a Ceph quincy.
Aktualizace	apt update && upgrade -y.
Nástroje	Nainstaluje htop, vim, curl, git, fail2ban, cockpit, netdata, ufw.
SSH	Povolí root přihlášení (volitelně upravte).
Uživatel admin	Vytvoří uživatele s heslem a SSH klíčem (pro bezpečnější přístup).
Firewall	Povolí porty 22, 8006, 3306 a zapne UFW.
fail2ban	Spustí a povolí.
ISO	Stáhne zadané ISO obrazy do /var/lib/vz/template/iso (pro VM).
Ceph	Inicializuje Ceph cluster na jednom uzlu (mon, mgr, OSD na zadaných discích, vytvoří CephFS).
Datacentrové předvolby	Nastaví výchozí úložiště, HA, email, metric server, vytvoří složky.
🔧 Přizpůsobení
Změňte proměnné na začátku skriptu (hesla, disky, IP sítě).

Pro Ceph na jednom uzlu stačí 1 OSD – doporučuji alespoň 2 disky pro replikaci.

Pokud nechcete Ceph, nechte pole CEPH_DISKS=() prázdné.

Seznam ISO můžete upravit dle potřeby.

Skript je navržen tak, aby byl bezpečný – před každou destruktivní operací se ptá (kromě instalace balíčků). V produkčním prostředí doporučuji proměnné pevně nastavit a spustit v režimu bez interakce.



Tím získáte plně automatizovaný nástroj pro přípravu USB.
