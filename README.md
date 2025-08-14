# Proxmox VE 8 zu 9 Upgrade Script - Analyse

## Übersicht

Das Script `pve8to9_upgrade.sh` automatisiert das In-Place-Upgrade von Proxmox VE 8.x auf Version 9 (basierend auf Debian 13 "Trixie").

**Autor:** Techie  
**Website:** https://callmetechie.de  
**Version:** 1.1 (2025-08-14)

## Hauptfunktionen

### Automatisierte Upgrade-Schritte
- **Repository-Konfiguration:** Wechsel zwischen no-subscription und enterprise Kanälen
- **Quellenbereinigung:** Zuverlässige Entfernung/Deaktivierung widersprüchlicher PVE-Quellen
- **Moderne APT-Konfiguration:** Verwendung von deb822-Quellenformat für Debian 13 + PVE 9
- **Vollständiges Dist-Upgrade:** Mit optionalem automatischem Neustart

## Kommandozeilen-Optionen

| Option | Beschreibung |
|--------|--------------|
| `--repo no-subscription` | Standard-Repository ohne Abonnement (Default) |
| `--repo enterprise` | Enterprise-Repository (Abonnement erforderlich) |
| `--enterprise` | Kurzform für Enterprise-Repository |
| `--no-subscription` | Kurzform für No-Subscription-Repository |
| `--reboot` | Automatischer Neustart nach Upgrade |
| `-y, --yes, --assume-yes` | Nicht-interaktiver Modus |
| `--allow-ceph` | Trotz Ceph-Installation fortfahren (nicht empfohlen) |
| `--remove-systemd-boot` | Entfernt systemd-boot Meta-Paket falls inaktiv |
| `-h, --help` | Zeigt Hilfe an |

## Sicherheitsfeatures

### Pre-Flight Checks
- **Root-Berechtigung:** Überprüfung auf Root-Ausführung
- **PVE-Version:** Validierung der aktuellen PVE 8.x Installation
- **Ceph-Erkennung:** Warnung bei Ceph-Installationen mit Abbruch-Option
- **Cluster-Status:** Anzeige des Cluster-Status falls vorhanden
- **VM/Container-Status:** Auflistung laufender VMs und Container

### Backup-Mechanismus
- **Automatische Sicherung:** Alle APT-Quellen werden vor Änderung gesichert
- **Timestamped Backups:** Eindeutige Verzeichnisnamen mit Datum/Zeit
- **Logging:** Vollständige Protokollierung in `/var/log/pve8to9-upgrade-*.log`

## Technische Details

### Repository-Konfiguration
Das Script verwendet das moderne **deb822-Format** für APT-Quellen:

**Debian 13 "Trixie" Quellen:**
- Main Repository: `http://deb.debian.org/debian`
- Updates: `trixie-updates`
- Security: `http://security.debian.org/debian-security`
- Komponenten: `main contrib non-free non-free-firmware`

**Proxmox VE 9 Quellen:**
- **No-Subscription:** `http://download.proxmox.com/debian/pve` (trixie/pve-no-subscription)
- **Enterprise:** `https://enterprise.proxmox.com/debian/pve` (trixie/pve-enterprise)

### Keyring-Management
- Automatischer Download und Installation der Proxmox Archive Keyrings
- Verwendung von `/usr/share/keyrings/proxmox-archive-keyring.gpg`
- Fallback-Mechanismen für curl/wget

## Upgrade-Prozess

### Phase 1: Vorbereitung
1. **Systemvalidierung** - PVE-Version und Berechtigung prüfen
2. **Status-Check** - Cluster, VMs, Container auflisten
3. **Pre-Check** - `pve8to9 --full` Kompatibilitätsprüfung (falls verfügbar)
4. **Ceph-Warnung** - Stopp bei Ceph-Installation (ohne `--allow-ceph`)

### Phase 2: Repository-Umstellung
1. **Backup erstellen** - Sicherung aller APT-Quellen
2. **Quellen bereinigen** - Entfernung alter .list/.sources Dateien
3. **Neue Quellen** - deb822-Format für Debian 13 und PVE 9
4. **Keyring-Setup** - Proxmox Archive Keyring installation
5. **Validierung** - Sicherstellung nur einer aktiven PVE-Quelle

### Phase 3: Upgrade-Durchführung
1. **APT Update** - Paketlisten aktualisieren
2. **Final PVE 8.x Updates** - Letzte Updates vor Dist-Upgrade
3. **Dist-Upgrade** - Hauptupgrade zu Debian 13/PVE 9
4. **Cleanup** - Entfernung obsoleter Pakete
5. **Verification** - Versionsüberprüfung nach Upgrade

## Fehlerbehandlung

### Robuste Skript-Architektur
- **Error Trapping:** `set -Eeuo pipefail` für strikte Fehlerbehandlung
- **Line-Level Debugging:** Automatische Fehlerprotokollierung mit Zeilennummer
- **Graceful Fallbacks:** Continue-on-error für nicht-kritische Operationen

### Spezielle Behandlungen
- **systemd-boot:** Erkennung und optionale Entfernung des Meta-Pakets
- **Interaktivität:** Automatische Fallbacks für nicht-interaktive Umgebungen
- **Multiple PVE Sources:** Automatische Bereinigung bei Konflikten

## Verwendungsbeispiele

### Standard-Upgrade (No-Subscription)
```bash
sudo ./pve8to9_upgrade.sh
```

### Enterprise-Upgrade mit Auto-Reboot
```bash
sudo ./pve8to9_upgrade.sh --enterprise --reboot
```

### Vollautomatisches Upgrade
```bash
sudo ./pve8to9_upgrade.sh --no-subscription -y --reboot
```

### Mit Ceph-Override (Riskant)
```bash
sudo ./pve8to9_upgrade.sh --allow-ceph
```

## Wichtige Hinweise

### ⚠️ Cluster-Umgebungen
- **Einzeln upgraden:** Knoten nacheinander, nicht parallel
- **Workload-Migration:** VMs/Container vor Upgrade verschieben
- **Cluster-Status:** Vor und nach Upgrade prüfen

### ⚠️ Ceph-Installationen
- **Nicht empfohlen:** Upgrade ohne vorherige Ceph-Migration
- **Reihenfolge:** Erst Ceph auf kompatible Version, dann PVE
- **Override-Option:** `--allow-ceph` nur für Experten

### ⚠️ Produktive Systeme
- **Backup:** Vollständige Systemsicherung vor Upgrade
- **Wartungsfenster:** Upgrade nur während geplanter Downtime
- **Testing:** Upgrade zuerst in Testumgebung validieren

## Logging und Monitoring

- **Log-Datei:** `/var/log/pve8to9-upgrade-YYYY-MM-DD-HHMMSS.log`
- **Real-time Output:** Parallele Ausgabe auf Terminal und Log
- **Timestamp-basiert:** Eindeutige Log-Dateien pro Ausführung

## Kompatibilität

- **Unterstützte Versionen:** Proxmox VE 8.x → 9.x
- **Ziel-System:** Debian 13 "Trixie"
- **Architektur:** AMD64/x86_64
- **Shell:** Bash (#!/usr/bin/env bash)

---

*Dieses Script automatisiert einen komplexen Upgrade-Prozess und sollte nur von erfahrenen Administratoren in produktiven Umgebungen eingesetzt werden. Immer vorher testen und Backups erstellen!*
