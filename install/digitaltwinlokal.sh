#!/usr/bin/env bash
# =============================================================================
#  🏘️  Proxmox DigitalTwinLokal – One-Click Installer
#  https://github.com/HatchetMan111/DigitalTwinLokal
#
#  Hostet lokale 3D-/2D-Dorfkarten (isometrischer digitaler Zwilling des
#  Heimatdorfs) als unprivilegierten LXC-Container. Nach der Installation
#  ist sofort das Demo-Dorf „Musterhausen" live – eigene Dörfer werden
#  vollautomatisch aus OpenStreetMap + Höhenmodell + Luftbild gebaut.
#
#  Installation (auf Proxmox VE als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DigitalTwinLokal/main/install/digitaltwinlokal.sh)"
#
#  Eigenes Heimatdorf direkt mitinstallieren:
#    .../install/digitaltwinlokal.sh --dorf "Wessobrunn" --radius 1500
#
#  Nachträglich weitere Dörfer hinzufügen (beliebig oft):
#    .../install/digitaltwinlokal.sh --dorf "Nachbardorf"
#
#  Update / Status / Deinstallieren / Debug:
#    .../install/digitaltwinlokal.sh --update | --status | --uninstall | --debug
# =============================================================================

set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
APP_NAME="digitaltwin"
REPO_URL="https://github.com/HatchetMan111/DigitalTwinLokal.git"
RAW_URL="https://raw.githubusercontent.com/HatchetMan111/DigitalTwinLokal/main/install/digitaltwinlokal.sh"
ONE_LINER="bash -c \"\$(wget -qLO - ${RAW_URL})\""

WEB_PORT=8000              # Web-UI (Dorfregal + 3D-/2D-Karten)
CT_ID=""                   # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="digitaltwin"
CT_STORAGE="local-lvm"
CT_ROOTFS=8                # GB (Debian + Python + einige Dorf-Datensätze)
CT_CORES=2
CT_MEMORY=2048             # MB (Pipeline: OSM + Höhen + Luftbild reicht das locker)
CT_SWAP=0
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_PASSWORD=""             # leer = automatisch generieren
CT_TEMPLATE=""

# Dorf-Bau-Parameter (für --dorf; mehrere --dorf-Flags möglich)
DORFS=()                   # Array der Dorfnamen aus --dorf
DORF_ZIP=""                # Postleitzahl – macht die Ortssuche eindeutig
DORF_COUNTRY="de"          # ISO-Ländercode für die PLZ-Suche
DORF_RADIUS=1500           # Halbbreite in Metern
DORF_BBOX=""               # optional w,s,e,n statt Ortsname
ORTHO_TILES="https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
ORTHO_Z=16
DORF_TITLE=""              # Default: Ortsname
DORF_SUBTITLE=""           # Default: leer
DORF_ATTRIBUTION="© OpenStreetMap-Mitwirkende · Luftbild: © Esri, Maxar, Earthstar Geographics"

UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
LIST_ONLY=false
EXPORT_SLUG=""
EXPORT_OUT=""
REMOVE_DORF=""
FORCE_RECREATE=false
ASSUME_YES=false
DEBUG=false
TMP_DIR=""
LOG_FILE="/tmp/digitaltwin-installer-$(date +%Y%m%d-%H%M%S).log"

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + Service), falls vorhanden.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 15 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + Service):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 40 /var/log/digitaltwin-setup.log 2>/dev/null
            echo "--- systemctl status digitaltwin ---"
            systemctl status digitaltwin --no-pager 2>/dev/null | head -n 12
            echo "--- journalctl -u digitaltwin ---"
            journalctl -u digitaltwin --no-pager 2>/dev/null | tail -n 20
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace:  --debug  (z. B. ${ONE_LINER} --debug)"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # $0-Fallback: `bash -c "$(wget ...)" --dorf X` belegt $0 mit dem ersten
    # Flag statt $1 – deshalb $0 wieder in die Argumentliste einsortieren.
    local -a args=("$@")
    if [[ "${0:0:1}" == "-" ]]; then
        args=("$0" "$@")
    fi

    while [[ ${#args[@]} -gt 0 ]]; do
        case "${args[0]}" in
            --id)             CT_ID="${args[1]}"; args=("${args[@]:2}") ;;
            --hostname)       CT_HOSTNAME="${args[1]}"; args=("${args[@]:2}") ;;
            --storage)        CT_STORAGE="${args[1]}"; args=("${args[@]:2}") ;;
            --rootfs)         CT_ROOTFS="${args[1]}"; args=("${args[@]:2}") ;;
            --cores)          CT_CORES="${args[1]}"; args=("${args[@]:2}") ;;
            --memory)         CT_MEMORY="${args[1]}"; args=("${args[@]:2}") ;;
            --swap)           CT_SWAP="${args[1]}"; args=("${args[@]:2}") ;;
            --bridge)         CT_BRIDGE="${args[1]}"; args=("${args[@]:2}") ;;
            --ip)             CT_IP="${args[1]}"; args=("${args[@]:2}") ;;
            --password)       CT_PASSWORD="${args[1]}"; args=("${args[@]:2}") ;;
            --template)       CT_TEMPLATE="${args[1]}"; args=("${args[@]:2}") ;;
            --port)           WEB_PORT="${args[1]}"; args=("${args[@]:2}") ;;
            --dorf)           DORFS+=("${args[1]}"); args=("${args[@]:2}") ;;
            --zip)            DORF_ZIP="${args[1]}"; args=("${args[@]:2}") ;;
            --country)        DORF_COUNTRY="${args[1]}"; args=("${args[@]:2}") ;;
            --radius)         DORF_RADIUS="${args[1]}"; args=("${args[@]:2}") ;;
            --bbox)           DORF_BBOX="${args[1]}"; args=("${args[@]:2}") ;;
            --tiles)          ORTHO_TILES="${args[1]}"; args=("${args[@]:2}") ;;
            --z)              ORTHO_Z="${args[1]}"; args=("${args[@]:2}") ;;
            --title)          DORF_TITLE="${args[1]}"; args=("${args[@]:2}") ;;
            --subtitle)       DORF_SUBTITLE="${args[1]}"; args=("${args[@]:2}") ;;
            --attribution)    DORF_ATTRIBUTION="${args[1]}"; args=("${args[@]:2}") ;;
            --remove-dorf)    REMOVE_DORF="${args[1]}"; args=("${args[@]:2}") ;;
            --export)         EXPORT_SLUG="${args[1]}"; args=("${args[@]:2}") ;;
            --out)            EXPORT_OUT="${args[1]}"; args=("${args[@]:2}") ;;
            --update)         UPDATE=true; args=("${args[@]:1}") ;;
            --uninstall)      UNINSTALL=true; args=("${args[@]:1}") ;;
            --status)         STATUS_CHECK=true; args=("${args[@]:1}") ;;
            --list)           LIST_ONLY=true; args=("${args[@]:1}") ;;
            --force-recreate) FORCE_RECREATE=true; args=("${args[@]:1}") ;;
            --yes|-y)         ASSUME_YES=true; args=("${args[@]:1}") ;;
            --debug)          DEBUG=true; args=("${args[@]:1}") ;;
            --help|-h)        usage; exit 0 ;;
            *)                die "Unbekanntes Argument: ${args[0]} (--help für Hilfe)" ;;
        esac
    done

    if $DEBUG; then
        set -x
        info "Debug-Modus aktiv (bash -x) – alles landet in $LOG_FILE"
    fi

    if [[ -n "$REMOVE_DORF" && -n "$EXPORT_SLUG" ]]; then
        die "--remove-dorf und --export können nicht kombiniert werden"
    fi

    # Numerische Eingaben validieren, bevor sie im Container landen
    [[ "$DORF_RADIUS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--radius muss eine Zahl sein (Meter): '$DORF_RADIUS'"
    [[ "$ORTHO_Z" =~ ^[0-9]+$ && "$ORTHO_Z" -ge 1 && "$ORTHO_Z" -le 19 ]] || die "--z muss eine Zahl 1–19 sein: '$ORTHO_Z'"
    [[ "$WEB_PORT" =~ ^[0-9]+$ && "$WEB_PORT" -ge 1 && "$WEB_PORT" -le 65535 ]] || die "--port muss eine Zahl 1–65535 sein: '$WEB_PORT'"
    [[ "$CT_ROOTFS" =~ ^[0-9]+$ ]] || die "--rootfs muss eine Zahl sein: '$CT_ROOTFS'"
    [[ "$CT_CORES" =~ ^[0-9]+$ ]] || die "--cores muss eine Zahl sein: '$CT_CORES'"
    [[ "$CT_MEMORY" =~ ^[0-9]+$ ]] || die "--memory muss eine Zahl sein: '$CT_MEMORY'"
}

usage() {
    cat <<USAGE
🏘️  Proxmox DigitalTwinLokal – One-Click Installer
   Hostet lokale isometrische 3D-/2D-Karten deines Heimatdorfs als LXC.
   Nach dem Einzeiler ist sofort das Demo-Dorf „Musterhausen" live.

Usage:
  ${ONE_LINER} [OPTIONS]

Use Cases:
  1) Installieren + Demo ansehen (Standard):
       ${ONE_LINER}
     Ohne Flags fragt der Installer interaktiv nach Ort + PLZ + Radius.
  2) Eigenes Heimatdorf vollautomatisch erstellen (OSM + Höhen + Luftbild):
       ${ONE_LINER} --dorf "Dein Dorf" --zip 82405
       ${ONE_LINER} --dorf "Dein Dorf" --zip 82405 --radius 2000
       ${ONE_LINER} --zip 82405            (Ortsname wird aus der PLZ aufgelöst)
       ${ONE_LINER} --bbox 11.49,48.09,11.54,48.13 --title "Mein Gebiet"
     Die PLZ macht die Ortssuche eindeutig (viele Dörfer heißen gleich).
  3) Weitere Dörfer hinzufügen (mehrfach aufrufbar, landen im Dorfregal):
       ${ONE_LINER} --dorf "Nachbardorf" --zip 869xx
  4) 2D-Karte je Dorf: http://<IP>:${WEB_PORT}/<dorf>/karte.html
  5) Dorf exportieren (Backup auf den Host):
       ${ONE_LINER} --export "Dein Dorf" --out /root/mein-dorf.tar.gz
  6) Dorf entfernen / auflisten / aktualisieren / entfernen:
       ${ONE_LINER} --remove-dorf "Dein Dorf" | --list | --update | --uninstall

Dorf-Optionen (wirken auf --dorf / --zip / --bbox):
  --zip PLZ           Postleitzahl – macht die Ortssuche eindeutig (Default: de)
  --country CODE      ISO-Ländercode für die PLZ-Suche (Default: de)
  --radius NUM        Halbbreite in Metern (Default: 1500)
  --bbox w,s,e,n      Bbox in Lon/Lat statt Ortssuche
  --tiles URL         XYZ-Template fürs Luftbild
                      (Default: Esri World Imagery, {z}/{y}/{x}-Reihenfolge ok)
  --z NUM             Kachel-Zoomstufe fürs Luftbild (Default: 16)
  --title TEXT        Kartentitel (Default: aufgelöster Ortsname)
  --subtitle TEXT     Untertitel (Default: leer)
  --attribution TEXT  Quellen-Hinweis (Pflicht bei echten Daten, ist vorbelegt)

Container-Optionen:
  --id NUM            Container-ID (Default: automatisch nächste freie ab 200)
  --hostname TEXT     Hostname (Default: digitaltwin)
  --storage TEXT      Proxmox Storage (Default: local-lvm)
  --rootfs NUM        RootFS in GB (Default: 8)
  --cores NUM         CPU-Kerne (Default: 2)
  --memory NUM        RAM in MB (Default: 2048)
  --swap NUM          Swap in MB (Default: 0)
  --bridge TEXT       Netzwerk-Bridge (Default: vmbr0)
  --ip ADDR           Statische IP (z. B. 192.168.1.50/24) oder "dhcp" (Default: dhcp)
  --password TEXT     Root-Passwort (Default: automatisch generiert)
  --template TEXT     CT-Template (Default: neuestes debian-12-standard via pveam)
  --port NUM          Web-UI-Port (Default: 8000)

Modi:
  --update            App-Code im Container aktualisieren (Dorf-Daten bleiben)
  --status            Status anzeigen
  --list              Gehostete Dörfer auflisten
  --export NAME       Dorf als tar.gz auf den Host sichern (--out optional)
  --remove-dorf NAME  Dorf aus dem Container entfernen
  --uninstall         Container vollständig entfernen
  --force-recreate    Bei bestehendem Container: löschen und neu installieren
  --yes, -y           Rückfragen automatisch mit "ja" beantworten
  --debug             Vollständiges bash -x-Log ausgeben
  --help              Diese Hilfe

Hinweis: Beim Bau eines Dorfs lädt der Container einmalig OSM-Daten,
Höhenkacheln und Luftbildkacheln aus dem Internet. Zur Laufzeit der
Web-UI bleiben alle Anfragen komplett lokal.
USAGE
}

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
# Nächste freie Container-ID finden (ID-Vorgabe wird bei Belegung erhöht)
find_free_id() {
    if [[ -z "$CT_ID" ]]; then
        CT_ID="$ID_SCAN_START"
    fi
    local orig_id="$CT_ID"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx -- "$CT_ID"; do
        CT_ID=$((CT_ID + 1))
    done
    # if statt [[ ]] && – sonst gibt die Funktion 1 zurück, wenn die ID frei war
    if [[ "$CT_ID" != "$orig_id" ]]; then
        info "Container $orig_id ist belegt – verwende stattdessen ID $CT_ID"
    fi
    return 0
}

# Existiert bereits ein Container mit dem Ziel-Hostnamen? → dessen ID
find_existing_ct() {
    pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" \
        'NR>1 { for (i=2; i<=NF; i++) if ($i==h) { print $1; exit } }'
}

ct_exists() {
    pct list 2>/dev/null | awk '{print $1}' | grep -qx -- "$1"
}

confirm() {
    if $ASSUME_YES; then return 0; fi
    local reply
    read -r -p "$1 [y/N]: " reply || return 1
    [[ "$reply" =~ ^[Yy]$ ]]
}

# Container-IP ermitteln – alles im Container ausführen, damit ein pct-Fehler
# nicht via pipefail die Zuweisung abbricht (|| true auf der Substitution).
ct_ip_of() {
    pct exec "$1" -- sh -c 'hostname -I | awk "{print \$1}"' 2>/dev/null || true
}

# Slugify im kleinen Maßstab auf dem Host (Spiegel des Inner-Scripts) – dient
# nur der URL-Verifikation; exotische Namen fallen auf eine weiche Warnung
# zurück statt die Installation abzubrechen.
host_slugify() {
    local s="${1,,}"
    s="${s//ä/ae}"; s="${s//ö/oe}"; s="${s//ü/ue}"; s="${s//ß/ss}"
    s=$(printf '%s' "$s" | tr -cs 'a-z0-9' '-')
    s="${s#-}"; s="${s%-}"
    echo "${s:-dorf}"
}

# ── Voraussetzungen prüfen ─────────────────────────────────────────────────
check_prerequisites() {
    header "Prüfe Voraussetzungen"

    if [[ $EUID -ne 0 && "${DT_SKIP_ROOT_CHECK:-0}" != "1" ]]; then
        die "Bitte als root ausführen (sudo bash ...)"
    fi
    command -v pct &>/dev/null || die "pct nicht gefunden – läuft dieses Script auf einem Proxmox VE Host?"

    # Template/Storage nur für Installations-Modi relevant
    if $UNINSTALL || $UPDATE || $STATUS_CHECK || $LIST_ONLY || [[ -n "$EXPORT_SLUG" ]] || [[ -n "$REMOVE_DORF" ]]; then
        return 0
    fi

    command -v pveam &>/dev/null || die "pveam nicht gefunden – ist Proxmox VE korrekt installiert?"

    if [[ -z "$CT_TEMPLATE" ]]; then
        local t
        t=$(pveam list local 2>/dev/null | grep -i "debian-12-standard" | sort -V | tail -1 || true)
        if [[ -z "$t" ]]; then
            info "Lade Debian-12-Template herunter (einmalig)..."
            local tpl_name
            tpl_name=$(pveam available --section system 2>/dev/null \
                | grep -o "debian-12-standard_[^ ]*\.tar\.zst" | sort -V | tail -1 || true)
            if [[ -z "$tpl_name" ]]; then
                die "Kein Debian-12-Template gefunden.\n  Bitte prüfen: pveam update && pveam available --section system"
            fi
            pveam download local "$tpl_name" 2>&1 | tail -3
            t=$(pveam list local 2>/dev/null | grep -i "debian-12-standard" | head -1 || true)
            if [[ -z "$t" ]]; then
                die "Template-Download fehlgeschlagen.\n  Bitte manuell: pveam update && pveam download local $tpl_name"
            fi
        fi
        CT_TEMPLATE=$(basename "$(echo "$t" | awk '{print $1}')")
    fi
    ok "Template: $CT_TEMPLATE"

    if [[ "$CT_IP" != "dhcp" && ! "$CT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ && ! "$CT_IP" =~ ^(dhcp6|auto|manual)$ ]]; then
        warn "CT_IP='$CT_IP' sieht nicht wie eine gültige IP/CIDR aus – pct create könnte fehlschlagen"
    fi
}

# ── Deinstallieren ─────────────────────────────────────────────────────────
do_uninstall() {
    local ct_id="$1"
    header "Entferne Container $ct_id ($CT_HOSTNAME)"

    confirm "Container $ct_id inkl. ALLER Dorf-Daten (Dorfregal, gebaute Dörfer) wirklich löschen?" \
        || die "Abgebrochen (mit --yes überspringst du die Rückfrage)."

    pct stop "$ct_id" 2>/dev/null || true
    sleep 2
    pct destroy "$ct_id" --purge 2>/dev/null
    ok "Container $ct_id entfernt"
    exit 0
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    local ct_id="$1"
    header "Status: Container $ct_id ($CT_HOSTNAME)"

    if ! ct_exists "$ct_id"; then
        warn "Container $ct_id existiert nicht"
        exit 0
    fi

    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    info "Container: $state"

    if [[ "$state" == *"running"* ]]; then
        local svc
        svc=$(pct exec "$ct_id" -- systemctl is-active digitaltwin 2>/dev/null || echo "unbekannt")
        if [[ "$svc" == "active" ]]; then
            ok "Service 'digitaltwin': active"
        else
            warn "Service 'digitaltwin': $svc"
            pct exec "$ct_id" -- sh -c 'systemctl status digitaltwin --no-pager 2>/dev/null | head -12; journalctl -u digitaltwin --no-pager 2>/dev/null | tail -15' || true
        fi

        do_list_villages "$ct_id"

        local ct_ip code
        ct_ip=$(ct_ip_of "$ct_id")
        if [[ -n "$ct_ip" ]]; then
            info "IP: $ct_ip"
            if command -v curl &>/dev/null; then
                # curl -w gibt bei Verbindungsfehler bereits '000' aus – kein '|| echo 000'!
                code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ct_ip}:${WEB_PORT}/" 2>/dev/null || true)
                if [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]]; then
                    ok "Web-UI antwortet: http://${ct_ip}:${WEB_PORT} (HTTP $code)"
                else
                    warn "Web-UI vom Host aus nicht erreichbar (HTTP ${code:-000})"
                fi
            fi
        else
            warn "Container hat keine IP"
        fi
    fi
    exit 0
}

# ── Dorf-Liste ─────────────────────────────────────────────────────────────
do_list_villages() {
    local ct_id="$1"
    info "Gehostete Dörfer:"
    pct exec "$ct_id" -- env DT_WEB_PORT="$WEB_PORT" bash /root/dt-setup.sh list 2>/dev/null \
        | sed 's/^/    /' || warn "  (keine Liste verfügbar – Container noch nicht eingerichtet?)"
    return 0
}

do_list() {
    local ct_id="$1"
    header "Dörfer in Container $ct_id"
    if ! ct_exists "$ct_id"; then
        warn "Container $ct_id existiert nicht"
        exit 0
    fi
    do_list_villages "$ct_id"
    local ct_ip
    ct_ip=$(ct_ip_of "$ct_id")
    if [[ -n "$ct_ip" ]]; then
        info "Dorfregal: http://${ct_ip}:${WEB_PORT}/"
    fi
    exit 0
}

# ── Dorf exportieren (tar.gz aus Container auf den Host) ───────────────────
do_export() {
    local ct_id="$1"
    header "Exportiere Dorf '$EXPORT_SLUG' aus Container $ct_id"

    if ! ct_exists "$ct_id"; then
        die "Container $ct_id existiert nicht"
    fi

    if [[ -z "$EXPORT_OUT" ]]; then
        EXPORT_OUT="./digitaltwin-${EXPORT_SLUG// /_}-$(date +%Y%m%d).tar.gz"
    fi
    info "Ziel: $EXPORT_OUT"

    # Wichtig: der Export-Modus des Inner-Scripts schreibt das tar.gz nach
    # stdout – deshalb darf er kein tee-Log auf stdout haben (Inner-Script
    # schaltet das Log für 'export' selbst ab).
    pct exec "$ct_id" -- bash /root/dt-setup.sh export "$EXPORT_SLUG" > "$EXPORT_OUT"

    if [[ -s "$EXPORT_OUT" ]] && tar -tzf "$EXPORT_OUT" >/dev/null 2>&1; then
        ok "Export erfolgreich: $EXPORT_OUT ($(du -h "$EXPORT_OUT" | awk '{print $1}'))"
        ok "Wiederherstellen: im Container /srv/digitaltwin entpacken + Service neu laden"
    else
        die "Export fehlgeschlagen oder Datei leer: $EXPORT_OUT"
    fi
    exit 0
}

# ── Dorf entfernen ─────────────────────────────────────────────────────────
do_remove_dorf() {
    local ct_id="$1"
    header "Entferne Dorf '$REMOVE_DORF' aus Container $ct_id"

    if ! ct_exists "$ct_id"; then
        die "Container $ct_id existiert nicht"
    fi

    confirm "Dorf '$REMOVE_DORF' wirklich aus dem Container entfernen?" \
        || die "Abgebrochen (mit --yes überspringst du die Rückfrage)."

    pct exec "$ct_id" -- env DT_DEBUG="$([[ $DEBUG == true ]] && echo 1 || echo 0)" \
        bash /root/dt-setup.sh remove-village "$REMOVE_DORF"
    ok "Dorf entfernt"
    do_list_villages "$ct_id"
    exit 0
}

# ── In-Container-Setup-Script erzeugen (idempotent) ────────────────────────
write_inner_script() {
    cat > "$TMP_DIR/dt-setup.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# DigitalTwinLokal In-Container-Setup (idempotent – safe für Update & Re-Run)
# Wird vom Installer via `pct push` + `pct exec` ausgeführt (als root).
#
# Modi:
#   base                 – Pakete, User, systemd-Unit
#   app [refresh-demo]   – App-Repo klonen/aktualisieren, Demo-Dorf, Dorfregal
#   village NAME         – echtes Dorf bauen (Optionen via DT_*-Umgebung)
#   remove-village NAME  – Dorf entfernen
#   list                 – Dörfer auflisten
#   export NAME          – Dorf als tar.gz nach stdout (KEIN Log auf stdout!)
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
[[ "${DT_DEBUG:-0}" == "1" ]] && set -x

CMD="${1:-base}"

# Log mitschneiden – ABER nicht im Export-Modus, dessen stdout ist die Datei
if [[ "$CMD" != "export" ]]; then
    exec > >(tee /var/log/digitaltwin-setup.log) 2>&1
fi

step() { echo -e "\n━━━ [setup] $* ━━━"; }

REPO_DIR="/opt/digitaltwinlokal"
REPO_URL="${DT_REPO_URL:-https://github.com/HatchetMan111/DigitalTwinLokal.git}"
SERVE_DIR="/srv/digitaltwin"
SERVICE_USER="digitaltwin"
WEB_PORT="${DT_WEB_PORT:-8000}"
REGISTRY="$SERVE_DIR/villages.json"
DEMO_DIR="$SERVE_DIR/musterhausen"

# ── Dorfregal generieren (Python) ──────────────────────────────────────────
write_regal_helper() {
    cat > /opt/dt-regal.py <<'REGALEOF'
#!/usr/bin/env python3
"""Dorfregal-Übersichtsseite für DigitalTwinLokal generieren.

Liest villages.json (Liste der Dorf-Slugs) und je Dorf data/scene/meta.json
und schreibt /srv/digitaltwin/index.html – eine lokal bedienbare Startseite
mit Karten-Thumbnails und Links auf 3D- und 2D-Ansicht.
"""
import json
import os
import html
import time

SERVE = "/srv/digitaltwin"
REGISTRY = os.path.join(SERVE, "villages.json")
OUT = os.path.join(SERVE, "index.html")


def esc(s):
    return html.escape(str(s or ""), quote=True)


def village_info(slug):
    meta = {}
    mp = os.path.join(SERVE, slug, "data", "scene", "meta.json")
    if os.path.exists(mp):
        try:
            with open(mp) as f:
                meta = json.load(f)
        except Exception as e:
            print("WARNUNG: meta.json von %s unlesbar: %s" % (slug, e))
    title = meta.get("title") or slug
    subtitle = meta.get("subtitle") or ""
    attribution = meta.get("attribution") or ""
    thumb = os.path.join(SERVE, slug, "data", "scene", "ground.jpg")
    has_thumb = os.path.exists(thumb)
    return {
        "slug": slug, "title": title, "subtitle": subtitle,
        "attribution": attribution,
        "thumb": "%s/data/scene/ground.jpg?v=%d" % (slug, int(time.time()))
        if has_thumb else "",
    }


def main():
    slugs = []
    if os.path.exists(REGISTRY):
        try:
            with open(REGISTRY) as f:
                data = json.load(f)
            slugs = data.get("villages", [])
        except Exception as e:
            print("WARNUNG: villages.json unlesbar: %s" % e)
    # Fallback: Dörfer direkt im Dateisystem finden
    for name in sorted(os.listdir(SERVE)):
        p = os.path.join(SERVE, name, "index.html")
        if os.path.isdir(os.path.join(SERVE, name)) and os.path.exists(p) \
                and name not in slugs and name[0] != ".":
            slugs.append(name)

    cards = []
    for slug in slugs:
        v = village_info(slug)
        thumb = (
            '<img src="%s" alt="%s" loading="lazy">'
            % (esc(v["thumb"]), esc(v["title"]))
        ) if v["thumb"] else '<div class="ph">🗺️</div>'
        cards.append(
            '<div class="card">'
            '<a class="thumb" href="%s/index.html">%s</a>'
            '<div class="card-body">'
            '<div class="t"><a href="%s/index.html">%s</a></div>'
            '<div class="s">%s</div>'
            '<div class="links">'
            '<a class="pill" href="%s/index.html">🏔️ 3D</a>'
            '<a class="pill" href="%s/karte.html">🗺️ 2D</a>'
            '</div>'
            '<div class="a">%s</div>'
            '</div></div>'
            % (esc(slug), thumb, esc(slug), esc(v["title"]), esc(v["subtitle"]),
               esc(slug), esc(slug), esc(v["attribution"]))
        )

    village_cards = "\n".join(cards) or (
        '<p class="empty">Noch keine Dörfer – füge eines hinzu:</p>'
        '<code>installer mit --dorf "Dein Dorf"</code>'
    )

    # .replace statt %-Formatierung – das CSS enthält Prozentzeichen
    page = """<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Dorfregal – Digitale Zwillinge</title>
<style>
:root { --paper:#eee7d7; --card:#fffdf6; --ink:#3d3527; --accent:#8d4a34; }
* { margin:0; padding:0; box-sizing:border-box; }
body { background:var(--paper); color:var(--ink); min-height:100vh;
  font-family:'Segoe UI',system-ui,-apple-system,sans-serif; padding:28px 20px 60px; }
.wrap { max-width:1060px; margin:0 auto; }
header { margin-bottom:26px; }
.eyebrow { font-size:11px; letter-spacing:.14em; text-transform:uppercase;
  opacity:.6; font-weight:600; }
h1 { font-size:clamp(24px,4vw,34px); margin:2px 0 4px; }
.sub { font-size:14px; opacity:.7; }
.grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(300px,1fr)); gap:18px; }
.card { display:flex; flex-direction:column; background:var(--card);
  border:1px solid rgba(61,53,39,.14); border-radius:14px; overflow:hidden;
  box-shadow:0 3px 12px rgba(60,45,25,.08); transition:transform .12s, box-shadow .12s; }
.card:hover { transform:translateY(-2px); box-shadow:0 8px 20px rgba(60,45,25,.14); }
.card .thumb { display:block; }
.card img { width:100%; height:170px; object-fit:cover; display:block; }
.card .ph { height:170px; display:flex; align-items:center; justify-content:center;
  font-size:44px; background:#e5ddca; }
.card-body { padding:14px 16px 12px; }
.card .t { font-weight:700; font-size:18px; }
.card .t a { color:inherit; text-decoration:none; }
.card .s { font-size:13px; opacity:.72; margin-top:2px; min-height:16px; }
.links { display:flex; gap:8px; margin-top:10px; flex-wrap:wrap; }
.pill { display:inline-block; font-size:12px; font-weight:600; color:var(--accent);
  border:1px solid rgba(141,74,52,.35); border-radius:999px; padding:3px 10px;
  background:rgba(141,74,52,.06); text-decoration:none; }
.card .a { font-size:10.5px; opacity:.55; margin-top:8px; }
.empty { grid-column:1/-1; padding:30px; text-align:center; opacity:.7; }
code { display:block; margin:10px auto 0; padding:10px 14px; background:#fffdf6;
  border:1px dashed rgba(61,53,39,.3); border-radius:8px; font-size:12.5px;
  max-width:640px; white-space:pre-wrap; }
footer { margin-top:34px; font-size:11.5px; opacity:.55; text-align:center; }
</style>
</head>
<body>
<div class="wrap">
<header>
  <div class="eyebrow">DigitalTwinLokal</div>
  <h1>🏘️ Dorfregal</h1>
  <div class="sub">Lokale digitale Zwillinge – isometrische 3D- und 2D-Karten, komplett offline</div>
</header>
<div class="grid">
__CARDS__
</div>
<footer>Läuft lokal im Heimnetz · Datenquellen je Dorf in der Karte vermerkt</footer>
</div>
</body>
</html>
""".replace("__CARDS__", village_cards)

    with open(OUT, "w") as f:
        f.write(page)
    print("Dorfregal geschrieben:", OUT, "(%d Dörfer)" % len(slugs))


if __name__ == "__main__":
    main()
REGALEOF
}

registry_update() {
    # $1 = slug, $2 = 0/1 (entfernen/hinzufügen)
    python3 - "$1" "$2" "$REGISTRY" <<'PYEOF'
import json, os, sys
slug, remove, path = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
data = {"villages": []}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        pass
slugs = [s for s in data.get("villages", []) if s != slug]
if not remove:
    if slug not in slugs:
        slugs.append(slug)
data["villages"] = slugs
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=1)
print("Registry:", slugs)
PYEOF
}

slugify() {
    python3 - "$1" <<'PYEOF'
import sys, unicodedata, re
s = sys.argv[1].strip().lower()
s = s.replace('ä','ae').replace('ö','oe').replace('ü','ue').replace('ß','ss')
s = unicodedata.normalize('NFKD', s)
s = ''.join(c for c in s if not unicodedata.combining(c))
s = re.sub(r'[^a-z0-9]+', '-', s).strip('-')
print(s or 'dorf')
PYEOF
}

cmd_base() {
    step "1/3 apt: Basispakete (python3, PIL, numpy, git)"
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        python3 python3-pil python3-numpy git curl ca-certificates

    step "2/3 Service-User + Verzeichnisse"
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd --system --home "$SERVE_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
    fi
    mkdir -p "$SERVE_DIR" "$REPO_DIR"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$SERVE_DIR"

    step "3/3 systemd-Unit (Port ${WEB_PORT})"
    cat > /etc/systemd/system/digitaltwin.service <<UNITEOF
[Unit]
Description=DigitalTwinLokal – lokale 3D-/2D-Dorfkarten
After=network-online.target
Wants=network-online.target

[Service]
User=${SERVICE_USER}
ExecStart=/usr/bin/python3 -m http.server ${WEB_PORT} --bind 0.0.0.0 --directory ${SERVE_DIR}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNITEOF
    systemctl daemon-reload
    systemctl enable digitaltwin.service
    systemctl restart digitaltwin.service
    echo -e "\n━━━ [setup] base abgeschlossen ━━━"
}

cmd_app() {
    step "App-Code laden (${REPO_URL})"
    if [[ -d "$REPO_DIR/.git" ]]; then
        git -C "$REPO_DIR" fetch origin main --depth 1
        git -C "$REPO_DIR" reset --hard origin/main
    else
        rm -rf "$REPO_DIR"
        git clone --depth 1 "$REPO_URL" "$REPO_DIR"
    fi
    if [[ ! -f "$REPO_DIR/web/index.html" ]]; then
        echo "FEHLER: $REPO_DIR/web/index.html fehlt nach dem Klonen – Repo prüfen: $REPO_URL"
        exit 1
    fi

    step "Demo-Dorf deployen (${DEMO_DIR})"
    if [[ ! -f "$DEMO_DIR/index.html" || "${DT_REFRESH_DEMO:-0}" == "1" ]]; then
        mkdir -p "$DEMO_DIR"
        cp -a "$REPO_DIR/web/." "$DEMO_DIR/"
        chown -R "$SERVICE_USER:$SERVICE_USER" "$SERVE_DIR"
        echo "Demo-Dorf deployt"
    else
        echo "Demo-Dorf vorhanden – unverändert (DT_REFRESH_DEMO=1 erzwingt Neu-Deployment)"
    fi

    step "Dorfregal generieren"
    write_regal_helper
    registry_update "musterhausen" 0
    python3 /opt/dt-regal.py
    chown "$SERVICE_USER:$SERVICE_USER" "$REGISTRY" "$SERVE_DIR/index.html" 2>/dev/null || true

    step "Service prüfen/starten"
    systemctl enable --now digitaltwin.service >/dev/null 2>&1 || true
    systemctl restart digitaltwin.service
    echo -e "\n━━━ [setup] app abgeschlossen ━━━"
}

build_village() {
    local NAME="$1"
    if [[ -z "$NAME" && -z "${DT_DORF_ZIP:-}" && -z "${DT_DORF_BBOX:-}" ]]; then
        echo "FEHLER: weder Dorfname noch PLZ/Bbox angegeben (village NAME)"
        exit 1
    fi

    if [[ ! -d "$REPO_DIR/web" ]]; then
        echo "App-Repo fehlt – rufe zuerst 'app' auf"
        cmd_app
    fi

    # Fester Arbeitsbereich – der finale Slug steht erst NACH der Ortssuche fest
    # (bei PLZ-only löst fetch_osm erst den Ortsnamen auf)
    local WS="$SERVE_DIR/.build/current"
    rm -rf "$WS"
    mkdir -p "$WS/web" "$WS/srtm13"

    # Shell (index/karte/css/js/vendor) aus dem App-Repo, Daten via Pipeline
    cp -a "$REPO_DIR/web/index.html" "$REPO_DIR/web/karte.html" \
          "$REPO_DIR/web/iso.css" "$REPO_DIR/web/iso.js" "$WS/web/"
    cp -a "$REPO_DIR/web/vendor" "$WS/web/"
    cp -a "$REPO_DIR/tools" "$WS/tools"
    cd "$WS"

    step "1/4 OSM-Daten laden (Overpass)${DT_DORF_ZIP:+, PLZ ${DT_DORF_ZIP}}"
    # Overpass ist flaky (Quota/Timeouts) – deshalb bis zu 3 Versuche mit Pause
    local osm_ok=0 osm_try
    for osm_try in 1 2 3; do
        if [[ -n "${DT_DORF_BBOX:-}" ]]; then
            if python3 tools/fetch_osm.py --bbox "$DT_DORF_BBOX" --radius "${DT_DORF_RADIUS:-1500}"; then osm_ok=1; break; fi
        else
            if python3 tools/fetch_osm.py --name "$NAME" --zip "${DT_DORF_ZIP:-}" \
                --country "${DT_DORF_COUNTRY:-de}" --radius "${DT_DORF_RADIUS:-1500}"; then osm_ok=1; break; fi
        fi
        echo "Versuch ${osm_try}/3 fehlgeschlagen – Overpass-Endpunkte beschäftigt? Warte 20 s..."
        sleep 20
    done
    if [[ "$osm_ok" != "1" ]]; then
        echo "FEHLER: OSM-Laden nach 3 Versuchen fehlgeschlagen (Overpass-Quota/Netz)."
        echo "Später erneut ausführen: dieses Script mit --dorf/--zip für dasselbe Dorf."
        exit 1
    fi
    [[ -f web/data/bbox.json ]] || { echo "FEHLER: fetch_osm hat keine bbox.json erzeugt"; exit 1; }

    python3 - <<'PYCHECK'
import json
with open("web/data/buildings.js") as f:
    d = json.loads(f.read().split("=", 1)[1].rstrip().rstrip(";"))
n = len(d.get("features", []))
print("Gebäude im Ausschnitt:", n)
if n == 0:
    print("FEHLER: Keine Gebäude in diesem Ausschnitt – Ort/Bbox/PLZ prüfen.")
    raise SystemExit(1)
PYCHECK

    # Aufgelösten Ortsnamen für Titel + Slug nutzen (PLZ-only → echter Name)
    local PLACE TITLE_BASE SLUG
    PLACE=$(python3 -c "import json;print(json.load(open('web/data/bbox.json')).get('place','') or '')")
    TITLE_BASE="$NAME"
    [[ -z "$TITLE_BASE" ]] && TITLE_BASE="$PLACE"
    [[ -z "$TITLE_BASE" ]] && TITLE_BASE="${DT_DORF_ZIP:-dorf}"
    SLUG=$(slugify "$TITLE_BASE")
    step "Dorf '$TITLE_BASE' aufgelöst (Slug: $SLUG) – installiere nach Abschluss"

    step "2/4 Höhenkacheln laden (Terrarium z13)"
    python3 tools/fetch_srtm.py --out srtm13

    step "3/4 Szene bauen (Luftbild + Höhenraster + meta.json)"
    local BUILD_ARGS=(--tiles "${DT_ORTHO_TILES}" --z "${DT_ORTHO_Z:-16}" --srtm-dir srtm13
        --title "${DT_DORF_TITLE:-$TITLE_BASE}" --attribution "${DT_DORF_ATTRIBUTION}")
    if [[ -n "${DT_DORF_SUBTITLE:-}" ]]; then
        BUILD_ARGS+=(--subtitle "$DT_DORF_SUBTITLE")
    fi
    if [[ -z "${DT_DORF_BBOX:-}" ]]; then
        # Fokus auf den Ort rahmen (ca. 45 % des Radius)
        BUILD_ARGS+=(--focus-radius "$(python3 -c "print(round(${DT_DORF_RADIUS:-1500} * 0.45))")")
    fi
    python3 tools/build_scene.py "${BUILD_ARGS[@]}"

    step "4/4 Boden malen + LoD2-Stub"
    python3 tools/stylize_ground.py
    [[ -f web/data/lod2.js ]] || echo 'window.LOD2={b:[]};' > web/data/lod2.js

    # Verifikation vor dem Deployment
    local f missing=""
    for f in index.html karte.html data/buildings.js data/roads.js data/places.js \
             data/scene/meta.json data/scene/height.json data/scene/ground.jpg data/lod2.js; do
        if [[ ! -s "web/$f" ]]; then missing="$missing $f"; fi
    done
    if [[ -n "$missing" ]]; then
        echo "FEHLER: nach dem Build fehlen Dateien:$missing"
        echo "Setup-Log oben prüfen (OSM-Quota? Kachel-Quelle?)"
        exit 1
    fi

    step "Dorf installieren (${SERVE_DIR}/${SLUG})"
    mkdir -p "$SERVE_DIR/$SLUG"
    cp -a web/. "$SERVE_DIR/$SLUG/"
    registry_update "$SLUG" 0
    python3 /opt/dt-regal.py
    chown -R "$SERVICE_USER:$SERVICE_USER" "$SERVE_DIR"
    rm -rf "$WS"

    echo ""
    echo "━━━ [setup] Dorf fertig: http://localhost:${WEB_PORT}/${SLUG}/ (3D) · /${SLUG}/karte.html (2D) ━━━"
    echo "━━━ [setup] Später referenzieren als: '$TITLE_BASE' (--remove-dorf/--export) ━━━"
}

cmd_remove_village() {
    local NAME="$1"
    local SLUG
    SLUG=$(slugify "$NAME")
    if [[ ! -d "$SERVE_DIR/$SLUG" ]]; then
        echo "Dorf '$NAME' ($SLUG) existiert nicht – nichts zu tun. Vorhanden:"
        bash "$0" list || true
        exit 1
    fi
    step "Entferne Dorf '$SLUG'"
    rm -rf "$SERVE_DIR/$SLUG"
    registry_update "$SLUG" 1
    python3 /opt/dt-regal.py
    chown "$SERVICE_USER:$SERVICE_USER" "$REGISTRY" "$SERVE_DIR/index.html" 2>/dev/null || true
    echo "Dorf '$SLUG' entfernt"
}

cmd_list() {
    python3 - "$REGISTRY" "$SERVE_DIR" "${WEB_PORT}" <<'PYEOF'
import json, os, sys
path, serve, port = sys.argv[1], sys.argv[2], sys.argv[3]
slugs = []
if os.path.exists(path):
    try:
        with open(path) as f:
            slugs = json.load(f).get("villages", [])
    except Exception:
        pass
if not slugs:
    print("(keine Dörfer registriert)")
for s in slugs:
    meta = {}
    mp = os.path.join(serve, s, "data", "scene", "meta.json")
    if os.path.exists(mp):
        try:
            with open(mp) as f:
                meta = json.load(f)
        except Exception:
            pass
    title = meta.get("title", s)
    print("• %s  →  http://<IP>:%s/%s/  (3D)  ·  /%s/karte.html  (2D)" % (title, port, s, s))
PYEOF
}

cmd_export() {
    local NAME="$1"
    local SLUG
    SLUG=$(slugify "$NAME")
    if [[ ! -d "$SERVE_DIR/$SLUG" ]]; then
        echo "FEHLER: Dorf '$NAME' ($SLUG) existiert nicht" >&2
        exit 1
    fi
    tar -czf - -C "$SERVE_DIR" "$SLUG"
}

case "$CMD" in
    base)           cmd_base ;;
    app)            cmd_app ;;
    village)        shift; build_village "${1:-}" ;;
    remove-village) shift; cmd_remove_village "${1:-}" ;;
    list)           cmd_list ;;
    export)         shift; cmd_export "${1:-}" ;;
    *)              echo "Unbekannter Modus: $CMD" >&2; exit 1 ;;
esac
INNEREOF
}

# ── Setup im Container ausführen (genutzt von install, update, --dorf) ──────
push_inner_script() {
    local ct_id="$1"
    TMP_DIR=$(mktemp -d /tmp/digitaltwin-install-XXXXXX)
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/dt-setup.sh" /root/dt-setup.sh
}

run_inner() {
    local ct_id="$1"; shift
    pct exec "$ct_id" -- env \
        DT_REPO_URL="${DT_HARNESS_REPO_URL:-$REPO_URL}" \
        DT_WEB_PORT="$WEB_PORT" \
        DT_DEBUG="$([[ $DEBUG == true ]] && echo 1 || echo 0)" \
        "$@"
}

# ── Eigenes Dorf bauen (von install + --dorf genutzt) ──────────────────────
build_dorf() {
    local ct_id="$1" name="$2"
    header "🏘️ Baue Dorf '${name:-PLZ $DORF_ZIP}' (OSM + Höhen + Luftbild – kann einige Minuten dauern)"

    run_inner "$ct_id" \
        DT_DORF_RADIUS="$DORF_RADIUS" \
        DT_DORF_ZIP="$DORF_ZIP" \
        DT_DORF_COUNTRY="$DORF_COUNTRY" \
        DT_DORF_BBOX="$DORF_BBOX" \
        DT_ORTHO_TILES="$ORTHO_TILES" \
        DT_ORTHO_Z="$ORTHO_Z" \
        DT_DORF_TITLE="$DORF_TITLE" \
        DT_DORF_SUBTITLE="$DORF_SUBTITLE" \
        DT_DORF_ATTRIBUTION="$DORF_ATTRIBUTION" \
        bash /root/dt-setup.sh village "$name"

    # Verifikation: Dorf + meta.json erreichbar. Slug-Spiegelung vom Inner-Script:
    # der finale Slug basiert auf dem aufgelösten Ortsnamen (PLZ-only → echter
    # Name aus der Ortssuche), deshalb zusätzlich die Registry abfragen.
    local slug code
    slug=$(host_slugify "${name:-$DORF_ZIP}")
    info "Verifiziere Dorf-URLs im Container (/${slug}/)..."
    for path in "/${slug}/index.html" "/${slug}/karte.html" "/${slug}/data/scene/meta.json"; do
        code=$(pct exec "$ct_id" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${WEB_PORT}${path}" 2>/dev/null || true)
        if [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]]; then
            ok "HTTP $code: $path"
        else
            warn "HTTP ${code:-000}: $path (Dorf evtl. unter anderem Slug abgelegt – Regal prüfen)"
        fi
    done
    return 0
}

# ── Verifikation: Service + Web-UI ─────────────────────────────────────────
verify_installation() {
    local ct_id="$1"
    header "Verifiziere Installation"

    info "Service prüfen..."
    local svc
    svc=$(pct exec "$ct_id" -- systemctl is-active digitaltwin 2>/dev/null || echo inactive)
    if [[ "$svc" != "active" ]]; then
        err "Service 'digitaltwin' läuft nicht (Status: $svc)."
        pct exec "$ct_id" -- sh -c 'systemctl status digitaltwin --no-pager -l | head -30; \
            echo "--- journalctl ---"; journalctl -u digitaltwin --no-pager | tail -40' || true
        die "Service-Check fehlgeschlagen.\n  Debug: pct enter $ct_id && journalctl -u digitaltwin -e"
    fi
    ok "Service läuft (systemctl is-active: active)"

    info "Warte auf Web-UI (Port ${WEB_PORT})..."
    local web_ok=false web_code
    for _ in $(seq 1 24); do
        # curl -w liefert bei Verbindungsfehler '000'; keine zweite Ausgabe via || echo
        web_code="$(pct exec "$ct_id" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            "http://127.0.0.1:${WEB_PORT}/" 2>/dev/null || true)"
        if [[ "$web_code" =~ ^[0-9]{3}$ && "$web_code" != "000" ]]; then
            web_ok=true
            break
        fi
        sleep 5
    done

    if ! $web_ok; then
        die "Web-UI auf Port ${WEB_PORT} antwortet nicht.\n  Debug: pct enter $ct_id && journalctl -u digitaltwin -e"
    fi
    ok "Web-UI erreichbar im Container (HTTP $web_code)"

    # Dorfregal + Demo-Dorf inhaltlich prüfen
    local regal_code demo_code
    regal_code=$(pct exec "$ct_id" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${WEB_PORT}/" 2>/dev/null || true)
    demo_code=$(pct exec "$ct_id" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${WEB_PORT}/musterhausen/data/scene/meta.json" 2>/dev/null || true)
    if [[ "$regal_code" == "200" ]]; then
        ok "Dorfregal liefert Inhalt (HTTP 200)"
    else
        warn "Dorfregal HTTP ${regal_code:-000} – index.html evtl. nicht generiert"
    fi
    if [[ "$demo_code" == "200" ]]; then
        ok "Demo-Dorf-Daten verfügbar (HTTP 200)"
    else
        warn "Demo-Dorf HTTP ${demo_code:-000}"
    fi

    # Externer Check vom Proxmox-Host (soft – Firewall/Netz kann berechtigt blocken)
    local ct_ip ext_code
    ct_ip=$(ct_ip_of "$ct_id")
    if [[ -n "$ct_ip" ]] && command -v curl &>/dev/null; then
        ext_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ct_ip}:${WEB_PORT}/" 2>/dev/null || true)
        if [[ "$ext_code" =~ ^[0-9]{3}$ && "$ext_code" != "000" ]]; then
            ok "Web-UI vom Host erreichbar: http://${ct_ip}:${WEB_PORT} (HTTP $ext_code)"
        else
            warn "Web-UI vom Host aus nicht erreichbar (HTTP ${ext_code:-000}) – im Container läuft sie; ggf. Firewall/Netz prüfen."
        fi
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "🏘️  DigitalTwinLokal ist bereit!"

    local ct_ip
    if [[ "$CT_IP" == "dhcp" ]]; then
        ct_ip=$(ct_ip_of "$CT_ID")
    else
        ct_ip="${CT_IP%%/*}"
    fi
    [[ -z "$ct_ip" ]] && ct_ip="<IP-ADRESSE>"

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  🏘️ Dorfregal:  http://${ct_ip}:${WEB_PORT}/   (alle Dörfer, 3D + 2D)${NC}"
    echo -e "  ${GREEN}  🗺️ Demo-Dorf:  http://${ct_ip}:${WEB_PORT}/musterhausen/  (3D)${NC}"
    echo -e "  ${GREEN}     └ 2D:      http://${ct_ip}:${WEB_PORT}/musterhausen/karte.html${NC}"
    echo -e "  ${GREEN}  🐚 Terminal:  pct enter ${CT_ID}${NC}"
    echo -e "  ${GREEN}  🔑 Root-PW:   ${CT_PASSWORD}${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Dein eigenes Heimatdorf (beliebig oft ausführbar):${NC}"
    echo "    ${ONE_LINER} --dorf \"Dein Dorf\""
    echo -e "  ${CYAN}Mit größerem Radius / eigener Bbox:${NC}"
    echo "    ${ONE_LINER} --dorf \"Dein Dorf\" --radius 2000"
    echo "    ${ONE_LINER} --bbox 11.49,48.09,11.54,48.13 --title \"Mein Gebiet\""
    echo ""
    echo -e "  ${CYAN}Verwaltung:${NC}"
    echo "  Dörfer auflisten:   ${ONE_LINER} --list"
    echo "  Dorf sichern:       ${ONE_LINER} --export \"Dein Dorf\" --out /root/dorf.tar.gz"
    echo "  Dorf entfernen:     ${ONE_LINER} --remove-dorf \"Dein Dorf\""
    echo "  App aktualisieren:  ${ONE_LINER} --update"
    echo "  Status:             ${ONE_LINER} --status"
    echo "  Deinstallieren:     ${ONE_LINER} --uninstall"
    echo ""
    echo -e "  ${CYAN}Hinweise:${NC}"
    echo "  · Beim Dorf-Bau lädt der Container einmalig OSM-, Höhen- und Luftbilddaten;"
    echo "    die fertige Web-UI läuft danach komplett lokal (kein Cloud-Zwang)."
    echo "  · Die Luftbild-Quelle ist per --tiles austauschbar (z. B. Bayern-Orthofotos)."
    echo ""
}

# ── Update (Container bleibt, App wird aktualisiert) ───────────────────────
do_update() {
    local ct_id="$1"
    header "Aktualisiere DigitalTwinLokal in Container $ct_id"

    push_inner_script "$ct_id"
    run_inner "$ct_id" DT_REFRESH_DEMO=1 bash /root/dt-setup.sh app
    verify_installation "$ct_id"
    do_list_villages "$ct_id"
    print_summary
    exit 0
}

# ── Container erstellen ────────────────────────────────────────────────────
create_container() {
    header "Erstelle LXC-Container (ID: $CT_ID)"

    pct create "$CT_ID" "local:vztmpl/${CT_TEMPLATE}" \
        --hostname "$CT_HOSTNAME" \
        --storage "$CT_STORAGE" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},firewall=0" \
        --password "$CT_PASSWORD" \
        --unprivileged 1 \
        --onboot 1 \
        --start 0 \
        2>&1 | tail -3

    ok "Container $CT_ID erstellt ($CT_CORES vCPU, ${CT_MEMORY} MB RAM, ${CT_ROOTFS} GB Disk, onboot=1, unprivileged)"
}

# ── Interaktive Gebiets-Frage (wenn kein --dorf angegeben wurde) ───────────
ask_for_area() {
    # Nur fragen, wenn installiert werden soll und nichts vorgegeben ist
    if [[ ${#DORFS[@]} -gt 0 || -n "$DORF_BBOX" || -n "$DORF_ZIP" || "$ASSUME_YES" == true \
          || "$UPDATE" == true || "$UNINSTALL" == true || "$STATUS_CHECK" == true \
          || "$LIST_ONLY" == true || -n "$EXPORT_SLUG" || -n "$REMOVE_DORF" ]]; then
        return 0
    fi
    # Ohne TTY (z. B. wget … | bash) keine Frage stellen – dann Demo-Installation
    if ! [[ -t 0 ]] && [[ "${DT_FORCE_ASK:-0}" != "1" ]]; then
        return 0
    fi

    header "Dein Gebiet"
    echo -e "  Du kannst jetzt direkt dein ${BOLD}Heimatdorf${NC} bauen lassen"
    echo -e "  (OSM-Gebäude/Straßen + Höhenmodell + Luftbild – alles automatisch, alles lokal):"
    echo ""
    local reply_name reply_zip reply_radius
    read -r -p "  Dorf- oder Ortsname (leer = nur Demo-Dorf installieren): " reply_name || reply_name=""
    if [[ -z "$reply_name" ]]; then
        # Auch PLZ-only erlauben: eindeutig + löst den Ortsnamen automatisch auf
        read -r -p "  Postleitzahl des Ortes (Enter = Abbrechen, nur Demo): " reply_zip || reply_zip=""
        if [[ -z "$reply_zip" ]]; then
            info "Nur Demo installieren – Dörfer später hinzufügen mit:  --dorf \"Dein Dorf\""
            return 0
        fi
    else
        read -r -p "  Postleitzahl des Ortes (empfohlen, gegen Namens-Doppelungen): " reply_zip || reply_zip=""
    fi
    reply_zip="${reply_zip// /}"
    if [[ -n "$reply_zip" && ! "$reply_zip" =~ ^[0-9]{3,10}$ ]]; then
        warn "PLZ '$reply_zip' sieht nicht nach einer Postleitzahl aus – ignoriere sie"
        reply_zip=""
    fi
    read -r -p "  Halbbreite des Ausschnitts in Metern [1500]: " reply_radius || reply_radius="1500"
    if ! [[ "$reply_radius" =~ ^[0-9]+$ ]]; then
        warn "Ungültige Zahl ('$reply_radius') – verwende 1500 m"
        reply_radius=1500
    fi
    DORF_RADIUS="$reply_radius"
    DORF_ZIP="$reply_zip"
    if [[ -z "$reply_name" ]]; then
        info "PLZ $DORF_ZIP wird beim Bau automatisch zum Ortsnamen aufgelöst."
    fi
    DORFS+=("$reply_name")
    ok "Gebiet '${reply_name:-PLZ $DORF_ZIP}' (±${DORF_RADIUS} m) wird nach der Installation gebaut."
    info "Titel/Attribution/Quelle per --title/--attribution/--tiles feinjustierbar (--help)."
    return 0
}

# ── Hauptprogramm ──────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    echo ""
    echo -e "  ${BOLD}🏘️  Proxmox DigitalTwinLokal – Installer${NC}"
    echo -e "  ${CYAN}https://github.com/HatchetMan111/DigitalTwinLokal${NC}"
    echo -e "  ${CYAN}Lokale 3D-/2D-Dorfkarten · Demo „Musterhausen“ inklusive${NC}"
    echo -e "  ${CYAN}Log: $LOG_FILE${NC}"
    echo ""

    check_prerequisites
    ask_for_area

    # Bestehenden Container anhand Hostname finden (ID-Vorgabe hat Vorrang)
    local existing_id=""
    if [[ -n "$CT_ID" ]] && ct_exists "$CT_ID"; then
        existing_id="$CT_ID"
    else
        existing_id=$(find_existing_ct || true)
    fi

    if $UNINSTALL; then
        if [[ -z "$existing_id" ]]; then
            die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden (--id angeben?)."
        fi
        do_uninstall "$existing_id"
    fi

    if $STATUS_CHECK; then
        if [[ -z "$existing_id" ]]; then
            die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden (--id angeben?)."
        fi
        do_status "$existing_id"
    fi

    if $LIST_ONLY; then
        if [[ -z "$existing_id" ]]; then
            die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden (--id angeben?)."
        fi
        do_list "$existing_id"
    fi

    if [[ -n "$EXPORT_SLUG" ]]; then
        if [[ -z "$existing_id" ]]; then
            die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden (--id angeben?)."
        fi
        do_export "$existing_id"
    fi

    if [[ -n "$REMOVE_DORF" ]]; then
        if [[ -z "$existing_id" ]]; then
            die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden (--id angeben?)."
        fi
        push_inner_script "$existing_id"
        do_remove_dorf "$existing_id"
    fi

    # --dorf auf bestehendem Container: nur das Dorf bauen
    # (Achtung: `! $FORCE_RECREATE` innerhalb [[ ]] wäre String-Logik – "false"
    # ist nicht-leer und damit truthy; deshalb explizit != true vergleichen.)
    if [[ ${#DORFS[@]} -gt 0 && -n "$existing_id" && "$FORCE_RECREATE" != true ]]; then
        CT_ID="$existing_id"
        header "Füge Dorf(er) zu bestehendem Container $existing_id hinzu"
        push_inner_script "$existing_id"
        local d
        for d in "${DORFS[@]}"; do
            build_dorf "$existing_id" "$d"
        done
        do_list_villages "$existing_id"
        print_summary
        exit 0
    fi

    if $UPDATE; then
        if [[ -z "$existing_id" ]]; then
            die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden (--id angeben?)."
        fi
        do_update "$existing_id"
    fi

    # Neuinstallation
    if [[ -n "$existing_id" ]]; then
        if $FORCE_RECREATE; then
            warn "--force-recreate: bestehender Container $existing_id wird GELÖSCHT (alle Dorf-Daten verloren)!"
            confirm "Wirklich neu erstellen?" || die "Abgebrochen. (Tipp: --update aktualisiert ohne Datenverlust)"
            pct stop "$existing_id" 2>/dev/null || true
            sleep 2
            pct destroy "$existing_id" --purge 2>/dev/null
            CT_ID=""
        else
            # ohne --dorf und ohne --force-recreate → Update-Modus
            info "Container '$CT_HOSTNAME' existiert bereits (ID $existing_id) – wechsle in den Update-Modus."
            info "(Neuinstallation erzwingen: --force-recreate · Dorf hinzufügen: --dorf \"Name\")"
            do_update "$existing_id"
        fi
    fi

    find_free_id

    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -hex 12 2>/dev/null \
            || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' || echo "changeme")
        info "Root-Passwort automatisch generiert"
    fi

    create_container

    pct start "$CT_ID" 2>&1 | tail -2
    ok "Container gestartet"

    info "Warte auf Netzwerk (DHCP/DNS-Race aktiv abwarten)..."
    local ip=""
    for _ in $(seq 1 60); do
        ip=$(ct_ip_of "$CT_ID")
        [[ -n "$ip" ]] && break
        sleep 1
    done
    if [[ -z "$ip" ]]; then
        die "Container hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $CT_ID -- ip a)"
    fi
    ok "Container-IP: $ip"

    header "Richte DigitalTwinLokal ein (Basis + App + Demo)"
    push_inner_script "$CT_ID"
    run_inner "$CT_ID" bash /root/dt-setup.sh base
    run_inner "$CT_ID" bash /root/dt-setup.sh app
    ok "Basis + App + Demo-Dorf eingerichtet"

    # Eigene Dörfer (falls --dorf angegeben)
    if [[ ${#DORFS[@]} -gt 0 ]]; then
        local d
        for d in "${DORFS[@]}"; do
            build_dorf "$CT_ID" "$d"
        done
    fi

    verify_installation "$CT_ID"
    do_list_villages "$CT_ID"
    print_summary
}

main "$@"
