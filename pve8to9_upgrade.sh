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
# v1.1 (2025-08-14)

set -Eeuo pipefail
trap 'echo "ERROR: Zeile $LINENO: $BASH_COMMAND" >&2' ERR

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
MAJOR="$(pveversion | awk -F'/' 'NR==1{print $2}' | cut -d'.' -f1)"
if [[ "$MAJOR" != "8" ]]; then
  echo "Abbruch: Erwartet PVE 8.x, gefunden: $(pveversion)" >&2; exit 1
fi
echo "[INFO] Gefundene PVE-Version: $(pveversion)"

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

# Ceph-Hardstop
if dpkg -l | grep -qE '^ii\s+ceph'; then
  echo "[WARN] Ceph-Pakete erkannt. Erst Ceph auf kompatible Version migrieren, dann PVE upgraden."
  [[ $ALLOW_CEPH -eq 1 ]] || { echo "Abbruch (ohne --allow-ceph)." >&2; exit 1; }
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

# ----------------------- APT-Quellen vorbereiten -----------------------
BK="$(bkdir)"; echo "[INFO] Sicherung alter APT-Quellen: $BK"

# 1) Bestehende Debian-Listen sichern/neutralisieren
shopt -s nullglob
[[ -f /etc/apt/sources.list ]] && mv /etc/apt/sources.list "$BK/sources.list.old"
for f in /etc/apt/sources.list.d/*.list; do mv "$f" "$BK/"; done
for f in /etc/apt/sources.list.d/*.sources; do
  # Wir behalten nur gezielt neu geschriebene Dateien, alles andere wird gesichert
  mv "$f" "$BK/"
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

# 4) Keyrings sicherstellen
echo "[INFO] apt update (vorbereitend) ..."
apt-get update || true
apt-get install -y --no-install-recommends ca-certificates curl wget debian-archive-keyring || true

if [[ ! -f /usr/share/keyrings/proxmox-archive-keyring.gpg ]]; then
  echo "[INFO] Lade Proxmox Archiv-Keyring ..."
  if command -v curl >/dev/null; then
    curl -fsSL "https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg" \
      -o /usr/share/keyrings/proxmox-archive-keyring.gpg
  else
    wget -qO /usr/share/keyrings/proxmox-archive-keyring.gpg \
      "https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
  fi
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

echo "[INFO] Letzte Updates unter PVE 8.x einspielen ..."
apt-get $APT_YES full-upgrade

echo "[INFO] Dist-Upgrade zu Debian 13 / PVE 9 starten ..."
apt-get $APT_YES full-upgrade

echo "[INFO] Obsolete Pakete entfernen ..."
apt-get $APT_YES autoremove --purge || true

echo "[INFO] Versionen nach Upgrade:"
pveversion -v || true
echo -n "Debian: "; cat /etc/debian_version || true
uname -a

echo "[INFO] Upgrade abgeschlossen."
if [[ $AUTO_REBOOT -eq 1 ]]; then
  echo "[INFO] Reboote jetzt ..."
  systemctl reboot
else
  echo "[HINWEIS] Bitte Neustart durchführen: 'reboot'"
fi
