#!/usr/bin/env bash
# Proxmox VE 8.x -> 9 (Debian 13 "Trixie") In-Place Upgrade
#
# Autor: Techie
# Website: https://callmetechie.de
#
# - Wählt Repo-Kanal: no-subscription (Default) oder enterprise
# - Entfernt/Deaktiviert gegenläufige PVE-Quellen zuverlässig
# - Setzt deb822-Quellen (Debian 13 + PVE 9)
# - Führt Dist-Upgrade aus, optional Auto-Reboot
# v1.3 (2026-05-06): Disk-Space-Check, dpkg-Konfliktstrategie, Custom-Repo-Erhalt,
#                    LVM-Autoactivation-Migration, GRUB-EFI-Check, apt-policy-Verifikation
# v1.4 (2026-05-06): GPG-Validierung des heruntergeladenen Keyrings, HA-Logs-Hinweis

set -Eeuo pipefail
on_error() {
  local rc=$?
  echo "ERROR: Zeile $LINENO: $BASH_COMMAND (rc=$rc)" >&2
  if [[ -n "${BK:-}" ]]; then
    echo "[HINWEIS] APT-Quellen-Backup liegt unter: $BK" >&2
  fi
  echo "[HINWEIS] Mögliche Reparatur-Schritte bei abgebrochenem Upgrade:" >&2
  echo "  apt-get -f install        # broken dependencies aufloesen" >&2
  echo "  dpkg --configure -a       # halbkonfigurierte Pakete fertigstellen" >&2
  echo "  apt-get $APT_YES full-upgrade   # Upgrade fortsetzen" >&2
  exit $rc
}
trap on_error ERR

# ----------------------- Flags / Defaults -----------------------
REPO_CHANNEL=""              # "no-subscription" | "enterprise" | "" (-> interaktiv)
AUTO_REBOOT=0
ASSUME_YES=0
ALLOW_CEPH=0
REMOVE_SYSTEMD_BOOT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_CHANNEL="${2:-}"; shift 2 ;;
    --enterprise) REPO_CHANNEL="enterprise"; shift ;;
    --no-subscription) REPO_CHANNEL="no-subscription"; shift ;;
    --reboot) AUTO_REBOOT=1; shift ;;
    --allow-ceph) ALLOW_CEPH=1; shift ;;
    --remove-systemd-boot) REMOVE_SYSTEMD_BOOT=1; shift ;;
    -y|--yes|--assume-yes) ASSUME_YES=1; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: pve8to9_upgrade.sh [--repo {no-subscription|enterprise}] [--reboot] [-y] [--allow-ceph] [--remove-systemd-boot]
  --repo no-subscription   : Proxmox PVE 9 "no-subscription" (Default)
  --repo enterprise        : Proxmox PVE 9 "enterprise" (Abo erforderlich)
  --reboot                 : automatischer Neustart am Ende
  -y, --yes                : nicht-interaktiv fortfahren (assume-yes)
  --allow-ceph             : trotz erkanntem Ceph weitermachen (nicht empfohlen)
  --remove-systemd-boot    : Meta-Paket 'systemd-boot' entfernen, falls nicht aktiv
EOF
      exit 0
      ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then echo "Bitte als root ausführen." >&2; exit 1; fi

LOG="/var/log/pve8to9-upgrade-$(date +%F-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
echo "[INFO] Logging: $LOG"

export DEBIAN_FRONTEND=noninteractive
APT_YES=""; [[ $ASSUME_YES -eq 1 ]] && APT_YES="-y"

# dpkg-Konfliktstrategie:
# - im nicht-interaktiven Modus (-y) werden lokale Konfigs erhalten (--force-confold),
#   bei Konflikten die Defaults aus dem Paket übernommen (--force-confdef).
# - im interaktiven Modus bleibt das Standardverhalten (Nutzer wird gefragt).
APT_CONF_OPTS=()
if [[ $ASSUME_YES -eq 1 ]]; then
  APT_CONF_OPTS=(-o "Dpkg::Options::=--force-confdef" -o "Dpkg::Options::=--force-confold")
  echo "[INFO] dpkg-Konfliktstrategie: lokale Configs behalten (--force-confold)"
fi

# ----------------------- Helpers -----------------------
bkdir() { local d="/root/pve8to9-backup-$(date +%F-%H%M%S)"; mkdir -p "$d"; echo "$d"; }
confirm() { [[ $ASSUME_YES -eq 1 ]] && return 0; read -r -p "$1 [yes/NO]: " a; [[ "${a,,}" == "yes" ]]; }
file_disable() { # rename or comment-out
  local f="$1"
  [[ -f "$f" ]] || return 0
  case "$f" in
    *.sources) mv "$f" "${f}.disabled";;
    *.list) sed -i 's/^\s*deb/# &/' "$f";;
  esac
}

# ----------------------- Preflight -----------------------
command -v pveversion >/dev/null || { echo "Dies ist kein Proxmox-Host (pveversion fehlt)." >&2; exit 1; }
PVE_FULL="$(pveversion | awk -F'/' 'NR==1{print $2}')"
IFS='.' read -r PVE_MAJ PVE_MIN PVE_PATCH <<< "$PVE_FULL"
PVE_MIN="${PVE_MIN:-0}"
PVE_PATCH="${PVE_PATCH%%[!0-9]*}"; PVE_PATCH="${PVE_PATCH:-0}"
if [[ "$PVE_MAJ" != "8" ]]; then
  echo "Abbruch: Erwartet PVE 8.x, gefunden: $(pveversion)" >&2; exit 1
fi
# Doku verlangt mind. PVE 8.4.1
if (( PVE_MIN < 4 )) || { (( PVE_MIN == 4 )) && (( PVE_PATCH < 1 )); }; then
  echo "Abbruch: PVE >= 8.4.1 erforderlich (gefunden: $PVE_FULL). Bitte zuerst auf 8.4.1+ aktualisieren." >&2
  exit 1
fi
echo "[INFO] Gefundene PVE-Version: $(pveversion) (>= 8.4.1 OK)"

# Disk-Space-Check (Doku: mind. 5 GB auf /, ideal >= 10 GB)
ROOT_AVAIL_KB="$(df -Pk / | awk 'NR==2{print $4}')"
ROOT_AVAIL_GB=$(( ROOT_AVAIL_KB / 1024 / 1024 ))
echo "[INFO] Freier Speicher auf /: ${ROOT_AVAIL_GB} GB"
if (( ROOT_AVAIL_GB < 5 )); then
  echo "Abbruch: < 5 GB frei auf / (gefunden: ${ROOT_AVAIL_GB} GB). Doku verlangt mind. 5 GB." >&2
  exit 1
elif (( ROOT_AVAIL_GB < 10 )); then
  echo "[WARN] Nur ${ROOT_AVAIL_GB} GB frei auf / – empfohlen sind >= 10 GB."
  [[ $ASSUME_YES -eq 1 ]] || confirm "Trotzdem fortfahren?" || { echo "Abbruch durch Benutzer."; exit 1; }
fi

# /boot und /var ebenfalls prüfen, falls eigene Mountpoints
for mp in /boot /var; do
  if mountpoint -q "$mp" 2>/dev/null; then
    AVAIL_GB=$(( $(df -Pk "$mp" | awk 'NR==2{print $4}') / 1024 / 1024 ))
    echo "[INFO] Freier Speicher auf $mp: ${AVAIL_GB} GB"
    if (( AVAIL_GB < 1 )); then
      echo "[WARN] < 1 GB frei auf $mp – Upgrade kann scheitern."
    fi
  fi
done

if systemctl is-active --quiet pve-cluster; then
  echo "[INFO] Clusterstatus (Kurz):"; pvecm status || true
  echo "[HINWEIS] In Clustern Knoten EINZELN upgraden (Workloads vorher verschieben/stoppen)."
fi

echo "[INFO] Laufende VMs (running):"
qm list 2>/dev/null | awk 'NR==1 || $0 ~ /running/ {print}'
echo "[INFO] Laufende Container (running):"
pct list 2>/dev/null | awk 'NR==1 || $0 ~ /running/ {print}'

if command -v pve8to9 >/dev/null; then
  echo "[INFO] Pre-Check: 'pve8to9 --full' ..."
  pve8to9 --full || true
  echo "[HINWEIS] WARN/FAIL aus dem Pre-Check vor dem Upgrade beheben."
else
  echo "[WARN] 'pve8to9' nicht gefunden – fahre fort."
fi

# Ceph-Erkennung + Versionscheck (Squid 19.2 erforderlich vor PVE-9-Upgrade)
CEPH_INSTALLED=0
if dpkg -l 2>/dev/null | grep -qE '^ii\s+ceph(\s|:)'; then
  CEPH_INSTALLED=1
  CEPH_VER="$(ceph --version 2>/dev/null | awk '{print $3}' || true)"
  CEPH_MAJ="${CEPH_VER%%.*}"
  CEPH_MAJ="${CEPH_MAJ%%[!0-9]*}"; CEPH_MAJ="${CEPH_MAJ:-0}"
  echo "[INFO] Ceph erkannt: ${CEPH_VER:-unbekannt}"
  if (( CEPH_MAJ < 19 )); then
    echo "[FAIL] Ceph >= 19.2 (Squid) erforderlich vor PVE 9 Upgrade. Gefunden: ${CEPH_VER:-unbekannt}"
    [[ $ALLOW_CEPH -eq 1 ]] || { echo "Abbruch: Erst Ceph auf Squid migrieren oder --allow-ceph setzen." >&2; exit 1; }
    echo "[WARN] --allow-ceph aktiv: trotz inkompatibler Ceph-Version weiter (riskant)."
  else
    echo "[INFO] Ceph-Version OK (Squid)."
  fi
fi

# systemd-boot Hinweis/Option
if dpkg -l | grep -qE '^ii\s+systemd-boot(\s|:)'; then
  IN_USE=0
  if command -v bootctl >/dev/null; then
    bootctl status 2>/dev/null | grep -qi 'systemd-boot' && IN_USE=1 || true
  fi
  if [[ $IN_USE -eq 0 ]]; then
    echo "[WARN] 'systemd-boot' Meta-Paket installiert, aber offenbar nicht aktiv."
    if [[ $REMOVE_SYSTEMD_BOOT -eq 1 ]]; then
      echo "[INFO] Entferne 'systemd-boot' ..."
      apt-get remove -y systemd-boot || true
    else
      echo "[HINWEIS] Optional mit --remove-systemd-boot entfernen lassen."
    fi
  else
    echo "[INFO] systemd-boot ist aktiv – keine Aktion."
  fi
fi

# ----------------------- Repo-Kanal wählen -----------------------
if [[ -z "$REPO_CHANNEL" ]]; then
  if [[ -t 0 && -t 1 ]]; then
    echo "[AUSWAHL] Welches Proxmox-Repo soll genutzt werden?"
    echo "  1) no-subscription (empfohlen ohne Abo) [Default]"
    echo "  2) enterprise (Abo erforderlich)"
    read -r -p "Bitte 1 oder 2 eingeben [1]: " CHOICE
    case "${CHOICE:-1}" in
      1) REPO_CHANNEL="no-subscription";;
      2) REPO_CHANNEL="enterprise";;
      *) REPO_CHANNEL="no-subscription";;
    esac
  else
    REPO_CHANNEL="no-subscription"
  fi
fi
case "$REPO_CHANNEL" in
  no-subscription|enterprise) echo "[INFO] Gewählter Repo-Kanal: $REPO_CHANNEL" ;;
  *) echo "Ungültiger --repo Wert: $REPO_CHANNEL" >&2; exit 2 ;;
esac

[[ $ASSUME_YES -eq 1 ]] || confirm "Fortfahren mit Quellen-Umschaltung auf Debian 13/PVE 9 ($REPO_CHANNEL)?" || { echo "Abbruch durch Benutzer."; exit 1; }

# ----------------------- Pre-Update unter PVE 8.x -----------------------
# Doku-konform: erst aktuelles 8.x voll patchen, dann Repos auf trixie umstellen.
echo "[INFO] Vor-Update unter aktueller PVE 8.x-Installation ..."
apt-get update
apt-get "${APT_CONF_OPTS[@]}" $APT_YES dist-upgrade

PVE_FULL_NEW="$(pveversion | awk -F'/' 'NR==1{print $2}' || true)"
echo "[INFO] PVE-Version nach Vor-Update: ${PVE_FULL_NEW:-unbekannt}"

# ----------------------- APT-Quellen vorbereiten -----------------------
BK="$(bkdir)"; echo "[INFO] Sicherung alter APT-Quellen: $BK"

# 1) Bestehende Quellen kategorisieren:
#    - Debian-/PVE-/Ceph-Quellen werden ins Backup verschoben (werden neu geschrieben)
#    - Custom-Quellen (Docker, Tailscale, eigene) bleiben erhalten; bookworm wird auf trixie umgestellt
KNOWN_RE='deb\.debian\.org|security\.debian\.org|download\.proxmox\.com|enterprise\.proxmox\.com'

handle_source_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if grep -qE "$KNOWN_RE" "$f" 2>/dev/null; then
    echo "[INFO] Bekannte Quelle nach Backup: $f"
    mv "$f" "$BK/"
  else
    echo "[INFO] Custom-Quelle erhalten: $f (Kopie im Backup)"
    cp -a "$f" "$BK/"
    if grep -q 'bookworm' "$f" 2>/dev/null; then
      sed -i.pre-trixie 's/bookworm/trixie/g' "$f"
      echo "[INFO]   bookworm -> trixie umgestellt in $f (Backup als $f.pre-trixie)"
    fi
  fi
}

shopt -s nullglob
[[ -f /etc/apt/sources.list ]] && mv /etc/apt/sources.list "$BK/sources.list.old"
for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  handle_source_file "$f"
done
shopt -u nullglob
echo "# verwaltet über deb822-Dateien (*.sources)" > /etc/apt/sources.list

# 2) Debian 13 "Trixie" deb822 schreiben
cat >/etc/apt/sources.list.d/debian.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Architectures: amd64

Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Architectures: amd64

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Architectures: amd64
EOF

# 3) PVE 9 Repo (exakt ein Kanal) deb822 schreiben
if [[ "$REPO_CHANNEL" == "enterprise" ]]; then
  cat >/etc/apt/sources.list.d/pve.sources <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Architectures: amd64
EOF
else
  cat >/etc/apt/sources.list.d/pve.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Architectures: amd64
EOF
fi

# 3b) Ceph-Repository (Squid) schreiben, falls Ceph installiert ist
if [[ $CEPH_INSTALLED -eq 1 ]]; then
  if [[ "$REPO_CHANNEL" == "enterprise" ]]; then
    cat >/etc/apt/sources.list.d/ceph.sources <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/ceph-squid
Suites: trixie
Components: enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Architectures: amd64
EOF
  else
    cat >/etc/apt/sources.list.d/ceph.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Architectures: amd64
EOF
  fi
  echo "[INFO] Ceph-Repository geschrieben (ceph-squid, $REPO_CHANNEL)."
fi

# 4) Keyrings sicherstellen
echo "[INFO] apt update (vorbereitend) ..."
apt-get update || true
apt-get install -y --no-install-recommends ca-certificates curl wget debian-archive-keyring || true

if [[ ! -f /usr/share/keyrings/proxmox-archive-keyring.gpg ]]; then
  echo "[INFO] Lade Proxmox Archiv-Keyring ..."

  # gpg ist Voraussetzung für Validierung
  if ! command -v gpg >/dev/null; then
    apt-get install -y --no-install-recommends gnupg || {
      echo "[FAIL] gnupg konnte nicht installiert werden – Keyring-Validierung nicht möglich." >&2
      exit 1
    }
  fi

  KEY_URL="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
  TMP_KEY="$(mktemp -t pve-keyring-XXXXXX.gpg)"

  if command -v curl >/dev/null; then
    curl -fsSL "$KEY_URL" -o "$TMP_KEY" || { rm -f "$TMP_KEY"; echo "[FAIL] Download fehlgeschlagen: $KEY_URL" >&2; exit 1; }
  else
    wget -qO "$TMP_KEY" "$KEY_URL" || { rm -f "$TMP_KEY"; echo "[FAIL] Download fehlgeschlagen: $KEY_URL" >&2; exit 1; }
  fi

  # 1) Datei muss eine valide GPG-Keyring-Struktur haben
  if ! gpg --show-keys --no-options "$TMP_KEY" >/dev/null 2>&1; then
    echo "[FAIL] Heruntergeladene Datei ist kein gültiger GPG-Keyring: $TMP_KEY" >&2
    rm -f "$TMP_KEY"
    exit 1
  fi

  # 2) Sanity-Check: UID muss "Proxmox" enthalten (verhindert komplett unsinnige Inhalte)
  if ! gpg --show-keys --no-options "$TMP_KEY" 2>/dev/null | grep -qi 'proxmox'; then
    echo "[FAIL] Keyring enthält keine Proxmox-UID – Abbruch." >&2
    gpg --show-keys --no-options "$TMP_KEY" 2>&1 | head -20 >&2 || true
    rm -f "$TMP_KEY"
    exit 1
  fi

  echo "[INFO] Keyring-Validierung OK:"
  gpg --show-keys --no-options "$TMP_KEY" 2>/dev/null | sed -n '1,6p' || true

  install -m 0644 "$TMP_KEY" /usr/share/keyrings/proxmox-archive-keyring.gpg
  rm -f "$TMP_KEY"
fi

# 5) Letzte Sicherheitsprüfung: es darf nur EINE PVE-Quelle aktiv sein
echo "[INFO] Prüfe aktive PVE-Quellen ..."
ACTIVE=$(grep -RilE 'proxmox.*debian/pve' /etc/apt/sources.list{,.d}/* | wc -l || true)
if [[ "$ACTIVE" -ne 1 ]]; then
  echo "[WARN] Erwartet 1 aktive PVE-Quelle, gefunden: $ACTIVE – korrigiere ..."
  # Deaktivieren alles PVE-bezogenen
  for f in /etc/apt/sources.list.d/pve*.list /etc/apt/sources.list.d/pve*.sources \
           /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.sources; do
    [[ -e "$f" ]] && file_disable "$f"
  done
  # Gewünschte Quelle erneut schreiben
  rm -f /etc/apt/sources.list.d/pve.sources
  if [[ "$REPO_CHANNEL" == "enterprise" ]]; then
    cat >/etc/apt/sources.list.d/pve.sources <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Architectures: amd64
EOF
  else
    cat >/etc/apt/sources.list.d/pve.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Architectures: amd64
EOF
  fi
fi

# ----------------------- Upgrade -----------------------
echo "[INFO] apt update ..."
apt-get update

echo "[INFO] APT-Policy nach Quellenwechsel (zur Verifikation):"
apt-cache policy 2>/dev/null | sed -n '1,40p' || true

echo "[INFO] Dist-Upgrade zu Debian 13 / PVE 9 starten ..."
apt-get "${APT_CONF_OPTS[@]}" $APT_YES full-upgrade

echo "[INFO] Obsolete Pakete entfernen ..."
apt-get $APT_YES autoremove --purge || true

# Post-Upgrade: LVM-Autoactivation-Migration (Pflicht laut Doku bei shared LVM-Storage)
LVM_MIGR=/usr/share/pve-manager/migrations/pve-lvm-disable-autoactivation
if [[ -x "$LVM_MIGR" ]]; then
  echo "[INFO] LVM-Autoactivation-Migration ausführen ..."
  "$LVM_MIGR" || echo "[WARN] LVM-Migration mit Fehler beendet – manuell prüfen."
else
  echo "[INFO] LVM-Migrationsskript nicht vorhanden – übersprungen."
fi

# Post-Upgrade: GRUB-EFI auf UEFI-Systemen sicherstellen
if [[ -d /sys/firmware/efi ]]; then
  if ! dpkg -l 2>/dev/null | grep -qE '^ii\s+grub-efi-amd64(\s|:)'; then
    echo "[WARN] EFI-System ohne grub-efi-amd64 erkannt – installiere ..."
    apt-get $APT_YES install grub-efi-amd64 || echo "[WARN] grub-efi-amd64 Installation fehlgeschlagen."
  else
    echo "[INFO] EFI-System mit grub-efi-amd64 OK."
  fi
fi

# Post-Upgrade: pve8to9-Re-Check ausführen, falls verfügbar
if command -v pve8to9 >/dev/null; then
  echo "[INFO] Post-Check: 'pve8to9 --full' ..."
  pve8to9 --full || true
fi

echo "[INFO] Versionen nach Upgrade:"
pveversion -v || true
echo -n "Debian: "; cat /etc/debian_version || true
uname -a

echo "[INFO] Upgrade abgeschlossen."

# Cluster-spezifische Hinweise nach Upgrade
if systemctl is-active --quiet pve-cluster; then
  echo "[HINWEIS] Cluster-Setup erkannt:"
  echo "  - Nach Reboot HA-Logs prüfen: journalctl -eu pve-ha-crm"
  echo "  - HA-Gruppen werden automatisch zu HA-Regeln migriert (Status verifizieren)"
  echo "  - Restliche Knoten erst nach Verifikation dieses Knotens upgraden"
fi

if [[ $AUTO_REBOOT -eq 1 ]]; then
  echo "[INFO] Reboote jetzt ..."
  systemctl reboot
else
  echo "[HINWEIS] Bitte Neustart durchführen: 'reboot'"
fi
