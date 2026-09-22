#!/usr/bin/env bash
# ============================================================================
#  vme-iscsi-setup
#  ----------------------------------------------------------------------------
#  Automated iSCSI initiator + multipath setup for HPE VM Essentials (and any
#  KVM/libvirt) hosts, in preparation for GFS2 cluster storage.
#
#  Validates the environment, configures ifaces, performs discovery, applies
#  CHAP (optional), logs in, sets autostart, and reports WWIDs for the GFS2
#  GUI step.
#
#  Usage:
#    sudo ./vme-iscsi-setup.sh [--config FILE] [--remote-hosts h1,h2,...]
#                              [--non-interactive] [--no-color] [--help]
#
#  Single-host:    sudo ./vme-iscsi-setup.sh
#  With config:    sudo ./vme-iscsi-setup.sh --config iscsi-setup.conf
#  Cluster sweep:  ./vme-iscsi-setup.sh --config iscsi-setup.conf \
#                       --remote-hosts host-a,host-b,host-c
#
#  Repo:    (your fork)
#  License: MIT
# ============================================================================

set -u
set -o pipefail

VERSION="1.2.2"
SCRIPT_NAME="vme-iscsi-setup"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

# ----------------------------------------------------------------------------
# Colour / UI
# ----------------------------------------------------------------------------
init_colours() {
    if [[ -n "${NO_COLOR:-}" ]] || [[ "${OPT_NO_COLOR:-0}" == "1" ]] || [[ ! -t 1 ]]; then
        C_RESET=""; C_BOLD=""; C_DIM=""
        C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
    else
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_RED=$'\033[0;31m'
        C_GREEN=$'\033[0;32m'
        C_YELLOW=$'\033[0;33m'
        C_CYAN=$'\033[0;36m'
    fi
}

ICON_OK="✓"
ICON_FAIL="✗"
ICON_WARN="⚠"
ICON_INFO="•"
ICON_STEP="►"
ICON_QUERY="?"

ui_banner() {
    local w=72
    local title="  ${SCRIPT_NAME}  ·  v${VERSION}  "
    local subtitle="  iSCSI initiator + multipath setup for HPE VM Essentials hosts  "
    echo
    printf '%s' "${C_CYAN}"
    printf '╔'; printf '═%.0s' $(seq 1 $w); printf '╗\n'
    printf '║%s%*s║\n' "${C_BOLD}${title}${C_RESET}${C_CYAN}" $((w - ${#title})) ""
    printf '║%s%*s║\n' "${subtitle}" $((w - ${#subtitle})) ""
    printf '╚'; printf '═%.0s' $(seq 1 $w); printf '╝\n'
    printf '%s' "${C_RESET}"
    echo
}

ui_phase() {
    local n="$1" total="$2" name="$3"
    echo
    printf '%s┌─ Phase %s/%s · %s ' "${C_CYAN}" "$n" "$total" "$name"
    local used=$(( 14 + ${#n} + ${#total} + ${#name} ))
    local rem=$(( 72 - used ))
    [[ $rem -lt 1 ]] && rem=1
    printf '─%.0s' $(seq 1 $rem)
    printf '┐%s\n' "${C_RESET}"
}

ui_phase_end()    { printf '%s└%s┘%s\n' "${C_CYAN}" "$(printf '─%.0s' $(seq 1 72))" "${C_RESET}"; }
ui_step()         { printf '%s%s%s %s\n' "${C_CYAN}" "${ICON_STEP}" "${C_RESET}" "$*"; }
ui_info()         { printf '  %s%s%s %s\n' "${C_DIM}" "${ICON_INFO}" "${C_RESET}" "$*"; }
ui_ok()           { printf '  %s%s%s %s\n' "${C_GREEN}" "${ICON_OK}" "${C_RESET}" "$*"; }
ui_warn()         { printf '  %s%s%s %s\n' "${C_YELLOW}" "${ICON_WARN}" "${C_RESET}" "$*" >&2; }
ui_fail()         { printf '  %s%s%s %s\n' "${C_RED}" "${ICON_FAIL}" "${C_RESET}" "$*" >&2; }
ui_die()          { ui_fail "$*"; echo; exit 1; }

# Right-aligned status line.  ui_check "Label" "ok"|"fail"|"warn"|"skip" "detail"
ui_check() {
    local label="$1" status="$2" detail="${3:-}"
    local width=58
    local dots
    if (( ${#label} >= width )); then dots=" "; else
        dots=$(printf '.%.0s' $(seq 1 $((width - ${#label})) ))
    fi
    case "$status" in
        ok)    printf '  %s %s%s %s%s\n' "$label" "${C_DIM}$dots${C_RESET}" "${C_GREEN}${ICON_OK}${C_RESET}" "${C_DIM}" "${detail}${C_RESET}" ;;
        fail)  printf '  %s %s%s %s%s\n' "$label" "${C_DIM}$dots${C_RESET}" "${C_RED}${ICON_FAIL}${C_RESET}"   "${C_RED}"  "${detail}${C_RESET}" ;;
        warn)  printf '  %s %s%s %s%s\n' "$label" "${C_DIM}$dots${C_RESET}" "${C_YELLOW}${ICON_WARN}${C_RESET}" "${C_YELLOW}" "${detail}${C_RESET}" ;;
        skip)  printf '  %s %s%s %s%s\n' "$label" "${C_DIM}$dots${C_RESET}" "${C_DIM}—${C_RESET}"             "${C_DIM}"  "${detail}${C_RESET}" ;;
    esac
}

ui_spinner_run() {
    # ui_spinner_run "Label" <command...>
    local label="$1"; shift
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local tmp; tmp=$(mktemp)
    "$@" >"$tmp" 2>&1 &
    local pid=$!
    local i=0
    if [[ -t 1 ]]; then
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r  %s%s%s %s' "${C_CYAN}" "${frames[i]}" "${C_RESET}" "$label"
            i=$(( (i+1) % ${#frames[@]} ))
            sleep 0.08
        done
        printf '\r\033[K'
    else
        printf '  · %s\n' "$label"
    fi
    wait "$pid"; local rc=$?
    SPINNER_OUTPUT=$(<"$tmp"); rm -f "$tmp"
    return $rc
}

ui_prompt() {
    # ui_prompt "Question" "default" -> echoes value
    local q="$1" def="${2:-}"
    local hint=""
    [[ -n "$def" ]] && hint=" ${C_DIM}[${def}]${C_RESET}"
    printf '  %s%s%s %s%s%s: ' "${C_YELLOW}" "${ICON_QUERY}" "${C_RESET}" "${C_BOLD}" "$q" "${C_RESET}${hint}" >&2
    local ans; read -r ans
    [[ -z "$ans" ]] && ans="$def"
    printf '%s' "$ans"
}

ui_prompt_secret() {
    # ui_prompt_secret "Question" -> echoes value, no terminal echo
    local q="$1"
    printf '  %s%s%s %s%s%s: ' "${C_YELLOW}" "${ICON_QUERY}" "${C_RESET}" "${C_BOLD}" "$q" "${C_RESET}" >&2
    local ans; read -rs ans; echo >&2
    printf '%s' "$ans"
}

ui_confirm() {
    # ui_confirm "Question" "y"|"n" -> returns 0 on yes
    local q="$1" def="${2:-n}" hint="[y/N]"
    [[ "$def" == "y" ]] && hint="[Y/n]"
    printf '  %s%s%s %s%s%s %s: ' "${C_YELLOW}" "${ICON_QUERY}" "${C_RESET}" "${C_BOLD}" "$q" "${C_RESET}" "$hint" >&2
    local ans; read -r ans
    [[ -z "$ans" ]] && ans="$def"
    [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

ui_choice() {
    # ui_choice "Question" "default" opt1 opt2 ... -> echoes chosen value
    local q="$1" def="$2"; shift 2
    local opts=("$@")
    printf '  %s%s%s %s%s%s\n' "${C_YELLOW}" "${ICON_QUERY}" "${C_RESET}" "${C_BOLD}" "$q" "${C_RESET}" >&2
    local i=1
    for o in "${opts[@]}"; do
        local mark=" "
        [[ "$o" == "$def" ]] && mark="*"
        printf '      %s%s%s) %s\n' "${C_CYAN}" "$i" "${C_RESET}" "${o}${mark:+ ${C_DIM}(default)${C_RESET}}" >&2
        i=$((i+1))
    done
    while :; do
        printf '    choice: ' >&2
        local ans; read -r ans
        [[ -z "$ans" ]] && { printf '%s' "$def"; return; }
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then
            printf '%s' "${opts[$((ans-1))]}"; return
        fi
        for o in "${opts[@]}"; do
            [[ "$o" == "$ans" ]] && { printf '%s' "$o"; return; }
        done
        ui_warn "invalid choice"
    done
}

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
LOG_FILE=""
log_init() {
    LOG_FILE="/var/log/${SCRIPT_NAME}-$(hostname -s)-$(date +%Y%m%d-%H%M%S).log"
    if ! : >"$LOG_FILE" 2>/dev/null; then
        LOG_FILE="/tmp/${SCRIPT_NAME}-$(hostname -s)-$(date +%Y%m%d-%H%M%S).log"
        : >"$LOG_FILE"
    fi
}
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOG_FILE" 2>/dev/null || true; }

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null; then
            ui_warn "re-executing under sudo"
            exec sudo -E "$SCRIPT_PATH" "$@"
        else
            ui_die "must be run as root"
        fi
    fi
}

detect_distro() {
    DISTRO_FAMILY="unknown"
    DISTRO_NAME=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_NAME="${PRETTY_NAME:-$NAME}"
        case "${ID:-}${ID_LIKE:-}" in
            *debian*|*ubuntu*)            DISTRO_FAMILY="debian" ;;
            *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) DISTRO_FAMILY="rhel" ;;
        esac
    fi

    case "$DISTRO_FAMILY" in
        debian)
            PKG_ISCSI="open-iscsi";       PKG_MPATH="multipath-tools"
            AUTOLOGIN_SVC="open-iscsi" ;;
        rhel)
            PKG_ISCSI="iscsi-initiator-utils"; PKG_MPATH="device-mapper-multipath"
            AUTOLOGIN_SVC="iscsi" ;;
        *)
            PKG_ISCSI="iscsi-initiator-utils"; PKG_MPATH="device-mapper-multipath"
            AUTOLOGIN_SVC="iscsi" ;;
    esac
}

pkg_installed() {
    local p="$1"
    case "$DISTRO_FAMILY" in
        debian) dpkg -s "$p" >/dev/null 2>&1 ;;
        rhel)   rpm -q "$p" >/dev/null 2>&1 ;;
        *)      command -v "$p" >/dev/null 2>&1 ;;
    esac
}

pkg_install() {
    local p="$1"
    case "$DISTRO_FAMILY" in
        debian) DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" >>"$LOG_FILE" 2>&1 ;;
        rhel)   if command -v dnf >/dev/null; then dnf install -y "$p" >>"$LOG_FILE" 2>&1
                else yum install -y "$p" >>"$LOG_FILE" 2>&1; fi ;;
        *)      return 1 ;;
    esac
}

service_active()  { systemctl is-active --quiet "$1"; }
service_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

valid_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

valid_iqn() {
    [[ "$1" =~ ^iqn\.[0-9]{4}-[0-9]{2}\.[a-zA-Z0-9.-]+(:.+)?$ ]] \
        || [[ "$1" =~ ^eui\.[0-9a-fA-F]{16}$ ]]
}

# Show a table of physical NICs (excluding lo, virtual bridges, veth) with link/IP/MTU.
list_nics() {
    printf '\n  %sAvailable NICs%s\n' "${C_BOLD}" "${C_RESET}"
    printf '  %s%-14s %-8s %-19s %-7s %-18s %s%s\n' "${C_DIM}" \
        "NAME" "STATE" "IPv4" "MTU" "MAC" "DRIVER" "${C_RESET}"
    local nic_path nic
    for nic_path in /sys/class/net/*/; do
        nic="${nic_path%/}"; nic="${nic##*/}"
        [[ "$nic" == "*" ]] && continue  # no matches
        # skip loopback and obvious virtuals
        [[ "$nic" == "lo" ]] && continue
        case "$nic" in
            docker*|virbr*|veth*|tap*|br-*|vnet*|ovs-*|cni*|tun*) continue ;;
        esac
        # skip if backed by a virtual driver directory
        if [[ -e /sys/class/net/"$nic"/device ]] || [[ "$nic" =~ ^(eno|enp|ens|eth|em|p[0-9]) ]]; then
            local state ip mtu mac drv
            state=$(cat /sys/class/net/"$nic"/operstate 2>/dev/null || echo "?")
            ip=$(ip -4 -o addr show "$nic" 2>/dev/null | awk '{print $4}' | head -1)
            ip="${ip:-—}"
            mtu=$(cat /sys/class/net/"$nic"/mtu 2>/dev/null || echo "?")
            mac=$(cat /sys/class/net/"$nic"/address 2>/dev/null || echo "?")
            drv=$(basename "$(readlink /sys/class/net/"$nic"/device/driver 2>/dev/null)" 2>/dev/null || echo "?")
            local color="$C_RESET"
            [[ "$state" == "up" ]] && color="$C_GREEN"
            [[ "$state" == "down" ]] && color="$C_DIM"
            printf '  %-14s %s%-8s%s %-19s %-7s %-18s %s\n' \
                "$nic" "$color" "$state" "${C_RESET}" "$ip" "$mtu" "$mac" "$drv"
        fi
    done
    echo
}

nic_exists()    { [[ -d /sys/class/net/"$1" ]]; }
nic_state()     { cat /sys/class/net/"$1"/operstate 2>/dev/null; }
nic_mtu()       { cat /sys/class/net/"$1"/mtu 2>/dev/null; }
nic_ipv4()      { ip -4 -o addr show "$1" 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1; }

ping_via() {
    # ping_via <src-nic> <dest-ip>  (one packet, 2s deadline)
    ping -I "$1" -c 1 -W 2 "$2" >/dev/null 2>&1
}

jumbo_ping_via() {
    # jumbo_ping_via <src-nic> <dest-ip> <payload-size>
    # -M do = set DF bit (don't fragment) so MTU mismatch surfaces
    ping -c 1 -W 2 -I "$1" -s "$3" -M "do" "$2" >/dev/null 2>&1
}

tcp_open() {
    # tcp_open <ip> <port>  (3s timeout)
    timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

# Look up the underlying NIC name for a given iSCSI iface name, using the
# parallel STORAGE_NICS / ISCSI_IFACES arrays.
nic_for_iface() {
    local target_iface="$1"
    local nics ifaces
    read -ra nics <<<"$STORAGE_NICS"
    read -ra ifaces <<<"$ISCSI_IFACES"
    local i
    for (( i=0; i<${#ifaces[@]}; i++ )); do
        if [[ "${ifaces[i]}" == "$target_iface" ]]; then
            printf '%s' "${nics[i]}"
            return 0
        fi
    done
    return 1
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
OPT_CONFIG=""
OPT_REMOTE_HOSTS=""
OPT_NON_INTERACTIVE=0
OPT_NO_COLOR=0
OPT_LIST_NICS=0

usage() {
    cat <<EOF
${SCRIPT_NAME} v${VERSION}

Usage:
  $0 [--config FILE] [--remote-hosts h1,h2,...] [--list-nics]
     [--non-interactive] [--no-color]

Options:
  --config FILE         Read settings from FILE (Bash key=value format).
                        Defaults to ./iscsi-setup.conf if present.
  --remote-hosts LIST   Comma-separated list of hosts. The script will scp
                        itself + config to each and execute via SSH.
                        Requires passwordless SSH and sudo on each host.
  --list-nics           Print the NIC inventory for this host and exit.
                        Useful for filling out a config file without sitting
                        through prompts.
  --non-interactive     Do not prompt; fail if any required value is missing.
  --no-color            Disable ANSI colour output.
  -h, --help            Show this help.
  -V, --version         Show version.

Environment:
  ISCSI_CHAP_USER       Override CHAP username (preferred over config file).
  ISCSI_CHAP_PASS       Override CHAP password.
  NO_COLOR              Disable colour (any non-empty value).
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)            OPT_CONFIG="$2"; shift 2 ;;
            --remote-hosts)      OPT_REMOTE_HOSTS="$2"; shift 2 ;;
            --list-nics)         OPT_LIST_NICS=1; shift ;;
            --non-interactive)   OPT_NON_INTERACTIVE=1; shift ;;
            --no-color)          OPT_NO_COLOR=1; shift ;;
            -h|--help)           usage; exit 0 ;;
            -V|--version)        echo "$SCRIPT_NAME v$VERSION"; exit 0 ;;
            *)                   echo "unknown argument: $1" >&2; usage; exit 2 ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Configuration loading
# ----------------------------------------------------------------------------
TARGET_IQN=""
TARGET_PORTALS=""
TARGET_PORT="3260"
STORAGE_NICS=""
ISCSI_IFACES=""
EXPECTED_MTU=""
SET_INITIATOR_NAME=""
INITIATOR_NAME_OVERRIDE=""
USE_CHAP=""
CHAP_USER=""
CHAP_PASS=""
WRITE_MULTIPATH_CONF=""
PARTIAL_PATH_POLICY="prompt"
ISCSI_TUNING_PROFILE=""
ISCSI_CMDS_MAX=""
ISCSI_QUEUE_DEPTH=""
NIC_PORTAL_PAIRING=""    # user override: "nic:portal nic:portal ..."
NIC_PORTAL_PAIRS=""      # derived internal: "iface:portal iface:portal ..."

load_config_file() {
    local path="$OPT_CONFIG"
    if [[ -z "$path" ]] && [[ -r ./iscsi-setup.conf ]]; then
        path="./iscsi-setup.conf"
    fi
    [[ -z "$path" ]] && { ui_info "no config file provided — will prompt for all values"; return; }
    [[ ! -r "$path" ]] && ui_die "config file not readable: $path"

    # Permission warning if it contains secrets
    if grep -qE '^\s*CHAP_(USER|PASS)\s*=\s*"?[^"]+"?\s*$' "$path"; then
        local mode; mode=$(stat -c '%a' "$path" 2>/dev/null)
        if [[ "$mode" != "600" && "$mode" != "400" ]]; then
            ui_warn "config file $path contains CHAP secrets but has mode $mode (recommend 600)"
        fi
    fi

    # shellcheck disable=SC1090
    . "$path"
    ui_ok "loaded config: $path"
}

# Pull env-var CHAP overrides (highest precedence)
apply_env_overrides() {
    [[ -n "${ISCSI_CHAP_USER:-}" ]] && CHAP_USER="$ISCSI_CHAP_USER"
    [[ -n "${ISCSI_CHAP_PASS:-}" ]] && CHAP_PASS="$ISCSI_CHAP_PASS"
}

# ----------------------------------------------------------------------------
# Interactive config completion
# ----------------------------------------------------------------------------
interactive_fill() {
    ui_step "Configuration"

    if [[ -z "$TARGET_IQN" ]]; then
        while :; do
            TARGET_IQN=$(ui_prompt "Target IQN" "")
            valid_iqn "$TARGET_IQN" && break
            ui_warn "doesn't look like a valid IQN (expected iqn.YYYY-MM.reverse-domain[:string])"
        done
    fi

    if [[ -z "$TARGET_PORTALS" ]]; then
        while :; do
            TARGET_PORTALS=$(ui_prompt "Target portal IP(s), space-separated" "")
            local ok=1; local p
            for p in $TARGET_PORTALS; do valid_ip "$p" || ok=0; done
            (( ok )) && [[ -n "$TARGET_PORTALS" ]] && break
            ui_warn "one or more entries is not a valid IPv4 address"
        done
    fi

    [[ -z "$TARGET_PORT" ]] && TARGET_PORT=$(ui_prompt "iSCSI TCP port" "3260")

    if [[ -z "$STORAGE_NICS" ]]; then
        list_nics
        while :; do
            STORAGE_NICS=$(ui_prompt "Storage NIC names (space-separated, ≥2 for MPIO)" "")
            local ok=1; local n
            for n in $STORAGE_NICS; do nic_exists "$n" || { ui_warn "no such NIC: $n"; ok=0; break; }; done
            local count; count=$(echo "$STORAGE_NICS" | wc -w)
            if (( ok && count >= 1 )); then
                (( count < 2 )) && ui_warn "only $count NIC given — MPIO won't actually be multipath"
                break
            fi
        done
    fi

    if [[ -z "$ISCSI_IFACES" ]]; then
        # build a suggestion: iface_<nicname>
        local suggested=""
        for n in $STORAGE_NICS; do suggested+="iface_${n} "; done
        suggested="${suggested% }"
        ISCSI_IFACES=$(ui_prompt "iSCSI iface names (same order, blank = use '${suggested}')" "$suggested")
    fi

    # iface count must match NIC count
    local nic_count iface_count
    nic_count=$(echo "$STORAGE_NICS"   | wc -w)
    iface_count=$(echo "$ISCSI_IFACES" | wc -w)
    [[ "$nic_count" -ne "$iface_count" ]] && ui_die "iface count ($iface_count) does not match NIC count ($nic_count)"

    if [[ -z "$EXPECTED_MTU" ]]; then
        EXPECTED_MTU=$(ui_choice "Expected MTU on storage NICs" "9000" "1500" "9000")
    fi

    if [[ -z "$SET_INITIATOR_NAME" ]]; then
        if ui_confirm "Set a custom InitiatorName for this host?" "y"; then
            SET_INITIATOR_NAME="yes"
        else
            SET_INITIATOR_NAME="no"
        fi
    fi

    if [[ "$SET_INITIATOR_NAME" == "yes" && -z "$INITIATOR_NAME_OVERRIDE" ]]; then
        local auto
        if command -v iscsi-iname >/dev/null 2>&1; then
            auto="$(iscsi-iname | sed 's/.open-iscsi//; s/:.*$//'):$(hostname -s)"
        else
            auto="iqn.$(date +%Y-%m).local:$(hostname -s)"
        fi
        INITIATOR_NAME_OVERRIDE=$(ui_prompt "Initiator IQN (blank = use '${auto}')" "$auto")
    fi

    if [[ -z "$USE_CHAP" ]]; then
        if ui_confirm "Enable CHAP authentication?" "n"; then
            USE_CHAP="yes"
        else
            USE_CHAP="no"
        fi
    fi

    if [[ "$USE_CHAP" == "yes" ]]; then
        [[ -z "$CHAP_USER" ]] && CHAP_USER=$(ui_prompt "CHAP username" "")
        if [[ -z "$CHAP_PASS" ]]; then
            CHAP_PASS=$(ui_prompt_secret "CHAP password (input hidden)")
            local confirm; confirm=$(ui_prompt_secret "CHAP password (confirm)")
            [[ "$CHAP_PASS" != "$confirm" ]] && ui_die "passwords do not match"
        fi
        local len=${#CHAP_PASS}
        if (( len < 12 || len > 16 )); then
            ui_warn "CHAP password length is ${len}; iSCSI spec requires 12–16 characters for full interop"
        fi
    fi

    if [[ -z "$WRITE_MULTIPATH_CONF" ]]; then
        if ui_confirm "Write /etc/multipath.conf with cluster-safe defaults?" "y"; then
            WRITE_MULTIPATH_CONF="yes"
        else
            WRITE_MULTIPATH_CONF="no"
        fi
    fi

    if [[ -z "$ISCSI_TUNING_PROFILE" ]]; then
        ISCSI_TUNING_PROFILE=$(ui_choice "iSCSI session tuning (queue depth + cmds_max)" "default" \
            "default" "conservative" "fast" "custom")
    fi
    if [[ "$ISCSI_TUNING_PROFILE" == "custom" ]]; then
        while :; do
            [[ -z "$ISCSI_CMDS_MAX"    ]] && ISCSI_CMDS_MAX=$(ui_prompt   "  node.session.cmds_max" "1024")
            [[ -z "$ISCSI_QUEUE_DEPTH" ]] && ISCSI_QUEUE_DEPTH=$(ui_prompt "  node.session.queue_depth" "128")
            if ! [[ "$ISCSI_CMDS_MAX"    =~ ^[0-9]+$ ]] || (( ISCSI_CMDS_MAX    < 1 )); then
                ui_warn "cmds_max must be a positive integer"; ISCSI_CMDS_MAX=""; continue
            fi
            if ! [[ "$ISCSI_QUEUE_DEPTH" =~ ^[0-9]+$ ]] || (( ISCSI_QUEUE_DEPTH < 1 )); then
                ui_warn "queue_depth must be a positive integer"; ISCSI_QUEUE_DEPTH=""; continue
            fi
            if (( ISCSI_QUEUE_DEPTH > ISCSI_CMDS_MAX )); then
                ui_warn "queue_depth ($ISCSI_QUEUE_DEPTH) > cmds_max ($ISCSI_CMDS_MAX) is unusual"
                if ui_confirm "Continue anyway?" "n"; then break; fi
                ISCSI_CMDS_MAX=""; ISCSI_QUEUE_DEPTH=""; continue
            fi
            break
        done
    fi
}

# ----------------------------------------------------------------------------
# NIC ↔ portal pairing
# ----------------------------------------------------------------------------
#
# Each storage NIC pairs with exactly ONE target portal. The pairing is
# deterministic and identical across every host in the cluster. Loops over
# (iface × portal) are wrong — they produce N×M sessions instead of the
# correct min(N,M).
#
# Rules:
#   N NICs, N portals               → positional: nics[i] ↔ portals[i]
#   1 NIC,  M portals               → single NIC talks to all M portals
#   N NICs, 1 portal                → all NICs share the one portal
#   N NICs, M portals, N≠M, N≥2, M≥2 → require explicit NIC_PORTAL_PAIRING
#
# NIC_PORTAL_PAIRING format (user-facing):     "eno3:10.10.20.10 eno4:10.10.20.11"
# NIC_PORTAL_PAIRS format (derived internal):  "iface_eno3:10.10.20.10 iface_eno4:10.10.20.11"
derive_nic_portal_pairs() {
    local nics ifaces portals
    read -ra nics    <<<"$STORAGE_NICS"
    read -ra ifaces  <<<"$ISCSI_IFACES"
    read -ra portals <<<"$TARGET_PORTALS"

    local n=${#ifaces[@]} m=${#portals[@]}

    # Explicit override (from config or interactive prompt) wins.
    if [[ -n "$NIC_PORTAL_PAIRING" ]]; then
        local p
        for p in $NIC_PORTAL_PAIRING; do
            if ! [[ "$p" =~ ^[a-zA-Z0-9_-]+:[0-9.]+$ ]]; then
                ui_die "NIC_PORTAL_PAIRING entry malformed: '$p' (want nic:portal)"
            fi
        done
        # Translate nic names → iface names using STORAGE_NICS→ISCSI_IFACES map
        local out=""
        for p in $NIC_PORTAL_PAIRING; do
            local nic="${p%%:*}" portal="${p#*:}"
            local iface=""
            local i
            for (( i=0; i<${#nics[@]}; i++ )); do
                if [[ "${nics[i]}" == "$nic" ]]; then iface="${ifaces[i]}"; break; fi
            done
            [[ -z "$iface" ]] && ui_die "NIC_PORTAL_PAIRING references unknown NIC: $nic"
            out+="${iface}:${portal} "
        done
        NIC_PORTAL_PAIRS="${out% }"
        log "NIC_PORTAL_PAIRS from explicit pairing: $NIC_PORTAL_PAIRS"
        return
    fi

    # Derive positionally.
    local out=""
    if (( n == m )); then
        local i
        for (( i=0; i<n; i++ )); do out+="${ifaces[i]}:${portals[i]} "; done
    elif (( n == 1 )); then
        local p
        for p in "${portals[@]}"; do out+="${ifaces[0]}:${p} "; done
    elif (( m == 1 )); then
        local iface
        for iface in "${ifaces[@]}"; do out+="${iface}:${portals[0]} "; done
    else
        # Ambiguous topology. Prompt if we can; otherwise die.
        if (( OPT_NON_INTERACTIVE )); then
            ui_die "ambiguous topology: $n NIC(s) × $m portal(s); set NIC_PORTAL_PAIRING explicitly"
        fi
        ui_warn "ambiguous topology: $n NICs × $m portals ($n ≠ $m). Explicit pairing needed."
        ui_info "expected format: 'nic:portal nic:portal ...'"
        ui_info "example:         '${nics[0]}:${portals[0]} ${nics[1]:-<nic>}:${portals[1]:-<portal>}'"
        while :; do
            NIC_PORTAL_PAIRING=$(ui_prompt "NIC↔portal pairing" "")
            [[ -z "$NIC_PORTAL_PAIRING" ]] && { ui_warn "required"; continue; }
            local ok=1 p
            for p in $NIC_PORTAL_PAIRING; do
                [[ "$p" =~ ^[a-zA-Z0-9_-]+:[0-9.]+$ ]] || { ok=0; break; }
            done
            (( ok )) && break
            ui_warn "one or more entries malformed"
            NIC_PORTAL_PAIRING=""
        done
        derive_nic_portal_pairs  # recurse with explicit pairing now set
        return
    fi
    NIC_PORTAL_PAIRS="${out% }"
    log "NIC_PORTAL_PAIRS derived positionally: $NIC_PORTAL_PAIRS"
}

# ----------------------------------------------------------------------------
# Summary + confirmation
# ----------------------------------------------------------------------------
show_summary() {
    echo
    printf '  %sConfiguration summary%s\n' "${C_BOLD}" "${C_RESET}"
    printf '  %s' "${C_DIM}"
    printf '─%.0s' $(seq 1 70); printf '%s\n' "${C_RESET}"

    kv() { printf '  %-26s %s\n' "$1" "$2"; }

    kv "Host"                "$(hostname -f 2>/dev/null || hostname)"
    kv "Distro"              "$DISTRO_NAME ($DISTRO_FAMILY family)"
    kv "Target IQN"          "$TARGET_IQN"
    kv "Target portals"      "$TARGET_PORTALS"
    kv "Target TCP port"     "$TARGET_PORT"
    kv "Storage NICs"        "$STORAGE_NICS"
    kv "iSCSI ifaces"        "$ISCSI_IFACES"
    kv "NIC ↔ portal pairs"  "$NIC_PORTAL_PAIRS"
    kv "Expected MTU"        "$EXPECTED_MTU"
    if [[ "$SET_INITIATOR_NAME" == "yes" ]]; then
        kv "Initiator name"  "$INITIATOR_NAME_OVERRIDE"
    else
        kv "Initiator name"  "(leave existing)"
    fi
    kv "CHAP"                "$USE_CHAP$( [[ "$USE_CHAP" == "yes" ]] && printf '  user=%s  pass=%s' "$CHAP_USER" "$(printf '%*s' ${#CHAP_PASS} '' | tr ' ' '*')" )"
    case "${ISCSI_TUNING_PROFILE:-default}" in
        default|"")   kv "iSCSI tuning" "default (OS values, conservative)" ;;
        conservative) kv "iSCSI tuning" "conservative (cmds_max=1024, queue_depth=128)" ;;
        fast)         kv "iSCSI tuning" "fast (cmds_max=2048, queue_depth=256)" ;;
        custom)       kv "iSCSI tuning" "custom (cmds_max=$ISCSI_CMDS_MAX, queue_depth=$ISCSI_QUEUE_DEPTH)" ;;
    esac
    kv "Write multipath.conf" "$WRITE_MULTIPATH_CONF"
    kv "Partial path policy" "$PARTIAL_PATH_POLICY"
    kv "Log file"            "$LOG_FILE"

    printf '  %s' "${C_DIM}"
    printf '─%.0s' $(seq 1 70); printf '%s\n' "${C_RESET}"
    echo

    if (( OPT_NON_INTERACTIVE )); then
        ui_info "non-interactive: proceeding"
        return 0
    fi
    if ! ui_confirm "Proceed with these settings?" "n"; then
        ui_die "aborted by user"
    fi
}

# ----------------------------------------------------------------------------
# Phase 2 — Pre-flight checks
# ----------------------------------------------------------------------------
PREFLIGHT_FAILED=0
preflight() {
    ui_phase 2 4 "Pre-flight"

    local needs_install=()
    local needs_enable=()

    # -- Read-only checks ---------------------------------------------------

    ui_step "Packages"
    local pkg
    for pkg in "$PKG_ISCSI" "$PKG_MPATH"; do
        if pkg_installed "$pkg"; then
            ui_check "package $pkg" ok "installed"
        else
            ui_check "package $pkg" warn "not installed"
            needs_install+=("$pkg")
        fi
    done

    ui_step "Services"
    local svc
    for svc in iscsid multipathd; do
        if ! systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 \
           && ! systemctl list-units --all "${svc}.service" >/dev/null 2>&1; then
            ui_check "service $svc" warn "unit not present (needs package)"
            needs_enable+=("$svc")
            continue
        fi
        if service_active "$svc"; then
            ui_check "service $svc" ok "active"
        else
            ui_check "service $svc" warn "inactive"
            needs_enable+=("$svc")
        fi
    done

    # Auto-login-at-boot service: a oneshot (iscsi on RHEL / open-iscsi on
    # Debian) that runs `iscsiadm -m node --loginall=automatic` at startup.
    # `node.startup=automatic` on a node record only triggers a login if THIS
    # service is enabled. Check is-enabled, not is-active.
    if ! systemctl list-unit-files "${AUTOLOGIN_SVC}.service" >/dev/null 2>&1; then
        ui_check "service $AUTOLOGIN_SVC (boot auto-login)" warn "unit not present"
        needs_enable+=("$AUTOLOGIN_SVC")
    elif systemctl is-enabled --quiet "$AUTOLOGIN_SVC" 2>/dev/null; then
        ui_check "service $AUTOLOGIN_SVC (boot auto-login)" ok "enabled"
    else
        ui_check "service $AUTOLOGIN_SVC (boot auto-login)" warn "not enabled — sessions won't auto-restore on reboot"
        needs_enable+=("$AUTOLOGIN_SVC")
    fi

    ui_step "Storage NICs"
    local nic
    for nic in $STORAGE_NICS; do
        if ! nic_exists "$nic"; then
            ui_check "NIC $nic exists" fail "not found"; PREFLIGHT_FAILED=1; continue
        fi
        ui_check "NIC $nic exists" ok
        local state; state=$(nic_state "$nic")
        if [[ "$state" == "up" ]]; then
            ui_check "  link state $nic" ok "$state"
        else
            ui_check "  link state $nic" fail "$state"
            PREFLIGHT_FAILED=1
        fi
        local ip; ip=$(nic_ipv4 "$nic")
        if [[ -n "$ip" ]]; then
            ui_check "  IPv4 on $nic" ok "$ip"
        else
            ui_check "  IPv4 on $nic" fail "no IPv4 assigned"
            PREFLIGHT_FAILED=1
        fi
        local mtu; mtu=$(nic_mtu "$nic")
        if [[ "$mtu" == "$EXPECTED_MTU" ]]; then
            ui_check "  MTU on $nic" ok "$mtu"
        else
            ui_check "  MTU on $nic" warn "actual=$mtu expected=$EXPECTED_MTU"
        fi
    done

    ui_step "Reachability"
    local payload=1472
    [[ "$EXPECTED_MTU" == "9000" ]] && payload=8972

    # Iterate the pairing, not the Cartesian product. On L3-segmented setups
    # (each NIC on its own subnet, each portal reachable only from its
    # paired NIC), pinging every NIC against every portal produces
    # false-negative failures for the routing-impossible combinations.
    local pair
    for pair in $NIC_PORTAL_PAIRS; do
        local iface="${pair%%:*}" portal="${pair#*:}"
        local nic; nic=$(nic_for_iface "$iface") || {
            ui_check "ping (pair $pair)" fail "iface not in ISCSI_IFACES"
            PREFLIGHT_FAILED=1
            continue
        }
        if ping_via "$nic" "$portal"; then
            ui_check "ping $nic → $portal (1pkt)" ok
        else
            ui_check "ping $nic → $portal (1pkt)" fail
            PREFLIGHT_FAILED=1
            continue
        fi
        if jumbo_ping_via "$nic" "$portal" "$payload"; then
            ui_check "jumbo ping $nic → $portal (DF, ${payload}B)" ok
        else
            ui_check "jumbo ping $nic → $portal (DF, ${payload}B)" warn "MTU mismatch or fragmentation"
        fi
    done

    for portal in $TARGET_PORTALS; do
        if tcp_open "$portal" "$TARGET_PORT"; then
            ui_check "TCP $portal:$TARGET_PORT open" ok
        else
            ui_check "TCP $portal:$TARGET_PORT open" fail
            PREFLIGHT_FAILED=1
        fi
    done

    # -- Fail fast on anything we can't fix automatically -------------------

    if (( PREFLIGHT_FAILED )); then
        echo
        ui_fail "pre-flight failed on a check that the script can't auto-resolve"
        ui_fail "(NIC, link, IP, ping, jumbo ping, or TCP reachability)"
        ui_info "fix the underlying issue and re-run — nothing has been changed"
        ui_phase_end
        exit 3
    fi

    # -- Explicit gate before any installs / service starts -----------------

    if (( ${#needs_install[@]} > 0 )) || (( ${#needs_enable[@]} > 0 )); then
        echo
        printf '  %sPre-flight identified prerequisites that need action:%s\n' "${C_BOLD}" "${C_RESET}"
        (( ${#needs_install[@]} > 0 )) && ui_info "install package(s):     ${needs_install[*]}"
        (( ${#needs_enable[@]} > 0 )) && ui_info "enable + start service(s): ${needs_enable[*]}"
        echo

        if (( OPT_NON_INTERACTIVE )); then
            ui_info "non-interactive: applying prerequisites automatically"
        else
            if ! ui_confirm "Apply these prerequisites now?" "y"; then
                ui_die "aborted — prerequisites not met, no changes made"
            fi
        fi

        for pkg in "${needs_install[@]}"; do
            if ui_spinner_run "installing $pkg" pkg_install "$pkg"; then
                ui_check "install $pkg" ok
            else
                ui_check "install $pkg" fail
                echo "$SPINNER_OUTPUT" >>"$LOG_FILE" 2>/dev/null || true
                PREFLIGHT_FAILED=1
            fi
        done
        for svc in "${needs_enable[@]}"; do
            local svc_ok=0
            case "$svc" in
                iscsi|open-iscsi)
                    # Oneshot — enable for next boot, do NOT --now (would try to
                    # log into automatic nodes before our apply phase has set any)
                    if systemctl enable "$svc" >>"$LOG_FILE" 2>&1; then svc_ok=1; fi
                    ;;
                *)
                    # Daemon — enable + start
                    if systemctl enable --now "$svc" >>"$LOG_FILE" 2>&1 \
                       && service_active "$svc"; then svc_ok=1; fi
                    ;;
            esac
            if (( svc_ok )); then
                ui_check "enable $svc" ok
            else
                ui_check "enable $svc" fail
                PREFLIGHT_FAILED=1
            fi
        done

        if (( PREFLIGHT_FAILED )); then
            echo
            ui_fail "prerequisite installation failed — see $LOG_FILE"
            ui_phase_end
            exit 3
        fi
    fi

    # -- Existing-state check (needs iscsiadm; safe to run now) -------------

    ui_step "Existing iSCSI state"
    if ! command -v iscsiadm >/dev/null 2>&1; then
        ui_check "iscsiadm available" fail "still missing after install"
        ui_phase_end
        exit 3
    fi
    local iface
    for iface in $ISCSI_IFACES; do
        if iscsiadm -m iface -I "$iface" >/dev/null 2>&1; then
            ui_check "iface $iface" warn "already exists — will update in place"
        else
            ui_check "iface $iface" ok "not present"
        fi
    done
    if iscsiadm -m session 2>/dev/null | grep -q "$TARGET_IQN"; then
        ui_check "existing sessions to target" warn "found — will be re-used"
    else
        ui_check "existing sessions to target" ok "none"
    fi

    ui_phase_end
}

# ----------------------------------------------------------------------------
# Phase 3 — Apply
# ----------------------------------------------------------------------------
apply_initiator_name() {
    [[ "$SET_INITIATOR_NAME" != "yes" ]] && { ui_check "initiator name" skip "leaving existing"; return; }
    local f=/etc/iscsi/initiatorname.iscsi
    [[ -f "$f" ]] && cp -a "$f" "${f}.bak-$(date +%Y%m%d-%H%M%S)"
    printf 'InitiatorName=%s\n' "$INITIATOR_NAME_OVERRIDE" >"$f"
    chmod 600 "$f"
    ui_check "initiator name" ok "$INITIATOR_NAME_OVERRIDE"
    systemctl restart iscsid >>"$LOG_FILE" 2>&1
    sleep 1
}

apply_multipath_conf() {
    if [[ "$WRITE_MULTIPATH_CONF" != "yes" ]]; then
        if [[ -r /etc/multipath.conf ]] && grep -qE 'user_friendly_names\s+yes' /etc/multipath.conf; then
            ui_check "multipath.conf cluster-safe" fail "user_friendly_names is 'yes' — GFS2 requires 'no'"
            exit 4
        fi
        ui_check "multipath.conf" skip "not writing (verify-only mode)"
        return
    fi
    local f=/etc/multipath.conf
    [[ -f "$f" ]] && cp -a "$f" "${f}.bak-$(date +%Y%m%d-%H%M%S)"
    cat >"$f" <<'EOF'
# Written by vme-iscsi-setup
defaults {
    user_friendly_names no
    find_multipaths     yes
    polling_interval    5
    path_grouping_policy multibus
    path_checker        tur
    failback            immediate
    no_path_retry       12
}

blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    devnode "^cciss!c[0-9]d[0-9]*"
}

blacklist_exceptions {
    property "(SCSI_IDENT_|ID_WWN)"
}
EOF
    chmod 644 "$f"
    ui_check "wrote $f" ok
    systemctl restart multipathd >>"$LOG_FILE" 2>&1
    sleep 1
    ui_check "multipathd restarted" ok
}

apply_ifaces() {
    local nics ifaces; read -ra nics <<<"$STORAGE_NICS"; read -ra ifaces <<<"$ISCSI_IFACES"
    local i
    for (( i=0; i<${#ifaces[@]}; i++ )); do
        local iface="${ifaces[i]}" nic="${nics[i]}"
        if ! iscsiadm -m iface -I "$iface" >/dev/null 2>&1; then
            iscsiadm -m iface -I "$iface" -o new >>"$LOG_FILE" 2>&1 \
                && ui_check "iface $iface created" ok \
                || { ui_check "iface $iface created" fail; exit 5; }
        else
            ui_check "iface $iface exists" ok "reusing"
        fi
        iscsiadm -m iface -I "$iface" --op=update -n iface.net_ifacename -v "$nic" >>"$LOG_FILE" 2>&1 \
            && ui_check "  $iface → $nic" ok \
            || { ui_check "  $iface → $nic" fail; exit 5; }
    done
}

apply_discovery() {
    # Discovery runs per pair — one iscsiadm sendtargets via each iface to
    # its paired portal. This is safe (min(N,M) discoveries, never the
    # Cartesian product), and it's *required* on strict L3-segmented setups
    # where each NIC is on its own /24 with no route to the other subnet:
    # running discovery via "default" iface would let the kernel pick a
    # source based on routing rules and fail for portals it can't reach.
    #
    # Each discovery may create iface-bound records for the portal it hit
    # (correct), and possibly for OTHER portals the target advertises in
    # its sendtargets response (unwanted). ensure_node_records will reconcile
    # those unwanted records against NIC_PORTAL_PAIRS.
    local pair advertised_all=""
    local found_target=0
    for pair in $NIC_PORTAL_PAIRS; do
        local iface="${pair%%:*}" portal="${pair#*:}"

        if ui_spinner_run "discovering $iface → $portal" \
            iscsiadm -m discovery -t sendtargets -I "$iface" -p "$portal"; then
            {
                printf '=== discovery output (%s → %s) ===\n' "$iface" "$portal"
                printf '%s\n' "$SPINNER_OUTPUT"
                printf '=== end discovery output ===\n'
            } >>"$LOG_FILE"
            if grep -q "$TARGET_IQN" <<<"$SPINNER_OUTPUT"; then
                ui_check "discover $iface → $portal" ok "found $TARGET_IQN"
                found_target=1
                advertised_all+="${SPINNER_OUTPUT}"$'\n'
            else
                ui_check "discover $iface → $portal" warn "target IQN not in response"
            fi
        else
            ui_check "discover $iface → $portal" fail
            {
                printf '=== FAILED discovery output (%s → %s) ===\n' "$iface" "$portal"
                printf '%s\n' "$SPINNER_OUTPUT"
                printf '=== end ===\n'
            } >>"$LOG_FILE"
            handle_partial_failure "discovery $iface → $portal failed"
        fi
    done

    if ! (( found_target )); then
        ui_fail "target IQN $TARGET_IQN was not advertised on any pair — check ACLs/IQN typo"
        exit 6
    fi

    # Verify each expected portal appeared in at least one discovery response.
    # (Some arrays only advertise the local portal; that's fine — the
    # per-pair discovery still creates the right record. Just a warning.)
    local portal
    for portal in $TARGET_PORTALS; do
        if grep -qE "^${portal}(:[0-9]+)?," <<<"$advertised_all"; then
            ui_check "portal $portal advertised" ok
        else
            ui_check "portal $portal advertised" warn "not in sendtargets response (per-pair discovery still handles this)"
        fi
    done

    # Log the state so postmortems have it
    {
        printf '=== node records after discovery ===\n'
        iscsiadm -m node 2>&1 || true
        printf '=== on-disk node files ===\n'
        find /etc/iscsi/nodes /var/lib/iscsi/nodes -type f 2>/dev/null || true
        printf '=== end ===\n'
    } >>"$LOG_FILE"
}

# Locate the node DB base directory for a given target IQN. Distros differ:
# Debian/Ubuntu use /etc/iscsi/nodes/, RHEL family uses /var/lib/iscsi/nodes/.
node_db_base() {
    local iqn="$1"
    local candidate
    for candidate in /etc/iscsi/nodes /var/lib/iscsi/nodes; do
        [[ -d "$candidate/$iqn" ]] && { printf '%s' "$candidate/$iqn"; return; }
    done
    return 1
}

# Return 0 (safe) if losing all iSCSI paths through $portal would still leave
# ≥1 active path per LUN on this host. Return 1 (unsafe) if any LUN would
# drop to zero active paths.
#
# This gate exists because live-mounted GFS2 will withdraw CLUSTER-WIDE — not
# just on this node — the moment a mount loses all its paths. Never delete
# a node record without asking this question first.
multipath_can_lose_path() {
    local losing_portal="$1"

    # Fresh install: no multipath state to protect — allow.
    if ! multipath -ll 2>/dev/null | grep -qE '^[0-9a-fA-F]{16,}'; then
        return 0
    fi

    # Identify sdX devices whose active iSCSI session is via $losing_portal
    local losing_devs
    losing_devs=$(iscsiadm -m session -P 3 2>/dev/null | awk -v p="$losing_portal" '
        /Current Portal:/ { in_portal = ($3 ~ "^"p":") }
        /Attached scsi disk/ && in_portal { for (i=1;i<=NF;i++) if ($i=="disk") print $(i+1) }
    ')
    # Nothing currently going through this portal — safe.
    [[ -z "$losing_devs" ]] && return 0

    multipath -ll 2>/dev/null | awk -v losing="$losing_devs" '
        BEGIN { split(losing, LA, /\n|[[:space:]]+/); for (k in LA) L[LA[k]]=1 }
        /^[0-9a-fA-F]{16,}/ { wwid=$1; active[wwid]=0 }
        /active ready running/ {
            # Path line: after tree prefix, fields are HCTL, dev, majmin, status...
            # Find the sdX field
            for (i=1;i<=NF;i++) if ($i ~ /^sd[a-z]+$/) { dev=$i; break }
            if (!(dev in L)) active[wwid]++
        }
        END { for (w in active) if (active[w] < 1) exit 1; exit 0 }
    '
}

# Reconcile: any (iface, portal) node record on disk for our target that is
# NOT in NIC_PORTAL_PAIRS gets logged out and deleted, after the multipath
# safety gate confirms losing that path is survivable.
reconcile_stale_records() {
    local base
    base=$(node_db_base "$TARGET_IQN") || {
        ui_check "reconcile" ok "no existing records"
        return 0
    }

    # Build desired set as an associative array for O(1) membership
    declare -A desired
    local pair
    for pair in $NIC_PORTAL_PAIRS; do desired["$pair"]=1; done

    local found_stale=0
    local portal_dir iface_file
    for portal_dir in "$base"/*; do
        [[ -d "$portal_dir" ]] || continue
        local portal_key="${portal_dir##*/}"    # e.g. "192.168.201.2,3260,1"
        local portal="${portal_key%%,*}"        # strip port,tpgt

        for iface_file in "$portal_dir"/*; do
            [[ -f "$iface_file" ]] || continue
            local iface="${iface_file##*/}"
            local key="${iface}:${portal}"

            if [[ -n "${desired[$key]:-}" ]]; then continue; fi   # keep

            found_stale=1
            ui_check "stale record $iface → $portal" warn "not in pairing — will remove"

            # SAFETY GATE — never withdraw a live GFS2 mount cluster-wide
            if ! multipath_can_lose_path "$portal"; then
                ui_fail "aborting: multipath cannot afford to lose path via $portal"
                ui_fail "one or more LUNs would drop to zero active paths"
                exit 11
            fi

            # Logout live session for this record (ignore errors — may not be up)
            iscsiadm -m node -T "$TARGET_IQN" -p "$portal" -I "$iface" --logout \
                >>"$LOG_FILE" 2>&1 || true

            if iscsiadm -m node -T "$TARGET_IQN" -p "$portal" -I "$iface" -o delete \
                    >>"$LOG_FILE" 2>&1; then
                ui_check "stale record $iface → $portal" ok "removed"
            else
                ui_check "stale record $iface → $portal" fail "delete failed"
                handle_partial_failure "could not delete stale record $iface → $portal"
            fi
        done
    done
    (( found_stale )) || ui_check "reconcile" ok "no stale records"
}

# Create exactly the node records we want, one per (iface, portal) pair.
# Idempotent: if a record already exists it's a no-op.
ensure_node_records() {
    reconcile_stale_records

    local pair
    for pair in $NIC_PORTAL_PAIRS; do
        local iface="${pair%%:*}" portal="${pair#*:}"

        if iscsiadm -m node -T "$TARGET_IQN" -p "$portal" -I "$iface" \
                >/dev/null 2>&1 \
           || iscsiadm -m node -T "$TARGET_IQN" -p "${portal}:${TARGET_PORT}" -I "$iface" \
                >/dev/null 2>&1; then
            ui_check "record $iface → $portal" ok "already bound"
            continue
        fi

        local err
        if err=$(iscsiadm -m node -o new \
                    -T "$TARGET_IQN" \
                    -p "${portal}:${TARGET_PORT}" \
                    -I "$iface" 2>&1); then
            ui_check "record $iface → $portal" ok "created"
            printf 'created node record: %s\n' "$err" >>"$LOG_FILE"
        else
            ui_check "record $iface → $portal" fail
            local line
            while IFS= read -r line; do
                [[ -n "$line" ]] && ui_info "iscsiadm: $line"
            done <<<"$err"
            log "ensure_node_records failed on $iface → $portal: $err"
            handle_partial_failure "could not create node record for $iface → $portal"
        fi
    done
}

# Update or insert a "key = value" line in /etc/iscsi/iscsid.conf, handling
# both uncommented and commented-out existing definitions.
set_iscsid_conf_value() {
    local f="$1" key="$2" value="$3"
    local key_re; key_re=$(printf '%s' "$key" | sed 's/[][\.*^$/]/\\&/g')
    if grep -qE "^[[:space:]#]*${key_re}[[:space:]]*=" "$f"; then
        sed -i -E "s|^[[:space:]#]*${key_re}[[:space:]]*=.*|${key} = ${value}|" "$f"
    else
        printf '\n%s = %s\n' "$key" "$value" >>"$f"
    fi
}

# Apply queue-depth / cmds_max tuning. Updates iscsid.conf (the template used
# for any future iSCSI targets on this host), restarts iscsid, and also writes
# the values directly to the existing node records for THIS target so they
# apply at next login on this run — not just to future targets.
#
# Existing live sessions retain their original negotiated values until next
# logout/login or reboot; that's iSCSI protocol behaviour, not a bug.
apply_iscsid_tuning() {
    if [[ -z "$ISCSI_TUNING_PROFILE" ]] || [[ "$ISCSI_TUNING_PROFILE" == "default" ]]; then
        ui_check "iSCSI tuning" skip "leaving OS defaults"
        return
    fi

    local cmds_max queue_depth
    case "$ISCSI_TUNING_PROFILE" in
        conservative) cmds_max=1024; queue_depth=128 ;;
        fast)         cmds_max=2048; queue_depth=256 ;;
        custom)       cmds_max="$ISCSI_CMDS_MAX"; queue_depth="$ISCSI_QUEUE_DEPTH" ;;
        *)            ui_check "iSCSI tuning" fail "unknown profile: $ISCSI_TUNING_PROFILE"; return ;;
    esac

    # 1) Update iscsid.conf for FUTURE node records on this host
    local f=/etc/iscsi/iscsid.conf
    if [[ -f "$f" ]]; then
        cp -a "$f" "${f}.bak-$(date +%Y%m%d-%H%M%S)"
        set_iscsid_conf_value "$f" "node.session.cmds_max"    "$cmds_max"
        set_iscsid_conf_value "$f" "node.session.queue_depth" "$queue_depth"
        ui_check "iscsid.conf updated" ok "cmds_max=$cmds_max queue_depth=$queue_depth"
        if systemctl restart iscsid >>"$LOG_FILE" 2>&1; then
            ui_check "iscsid restarted" ok
            sleep 1
        else
            ui_check "iscsid restarted" warn "non-fatal — values still written"
        fi
    else
        ui_check "iscsid.conf" warn "not found at $f — global tuning skipped"
    fi

    # 2) Update the node records we actually plan to use (one per pair —
    #    not the Cartesian product) so tuning applies at next login.
    local pair
    for pair in $NIC_PORTAL_PAIRS; do
        local iface="${pair%%:*}" portal="${pair#*:}"
        local portal_spec="$portal"
        if ! iscsiadm -m node -T "$TARGET_IQN" -p "$portal" -I "$iface" >/dev/null 2>&1 \
           && iscsiadm -m node -T "$TARGET_IQN" -p "${portal}:${TARGET_PORT}" -I "$iface" >/dev/null 2>&1; then
            portal_spec="${portal}:${TARGET_PORT}"
        fi
        if iscsiadm -m node -T "$TARGET_IQN" -p "$portal_spec" -I "$iface" \
                --op=update -n node.session.cmds_max -v "$cmds_max" >>"$LOG_FILE" 2>&1 \
           && iscsiadm -m node -T "$TARGET_IQN" -p "$portal_spec" -I "$iface" \
                --op=update -n node.session.queue_depth -v "$queue_depth" >>"$LOG_FILE" 2>&1; then
            ui_check "tuned $iface → $portal" ok "cmds=$cmds_max qd=$queue_depth"
        else
            ui_check "tuned $iface → $portal" warn "per-record update failed (see log)"
        fi
    done

    # 3) Warn if pre-existing sessions exist — they keep old values until re-login
    if iscsiadm -m session 2>/dev/null | grep -q "$TARGET_IQN"; then
        ui_info "pre-existing sessions retain old values until next logout/login or reboot"
    fi
}

# Helper: write the three CHAP keys (authmethod, username, password) for one
# (iface, portal) pair, with bare-IP→IP:port fallback. Returns 0 on success,
# 1 on failure (the caller is responsible for handle_partial_failure).
set_chap_record() {
    local iface="$1" portal="$2"
    local err="" failed_step=""

    # Some iscsiadm builds match node records only by IP:port — try bare IP
    # first, fall back to IP:port if that misses.
    local portal_spec="$portal"
    if ! iscsiadm -m node -T "$TARGET_IQN" -p "$portal" -I "$iface" >/dev/null 2>&1 \
       && iscsiadm -m node -T "$TARGET_IQN" -p "${portal}:${TARGET_PORT}" -I "$iface" >/dev/null 2>&1; then
        portal_spec="${portal}:${TARGET_PORT}"
        log "using portal spec $portal_spec for $iface (bare IP did not match)"
    fi

    err=$(iscsiadm -m node -T "$TARGET_IQN" -p "$portal_spec" -I "$iface" \
          --op=update -n node.session.auth.authmethod -v CHAP 2>&1) \
        || failed_step="authmethod"
    if [[ -z "$failed_step" ]]; then
        err=$(iscsiadm -m node -T "$TARGET_IQN" -p "$portal_spec" -I "$iface" \
              --op=update -n node.session.auth.username -v "$CHAP_USER" 2>&1) \
            || failed_step="username"
    fi
    if [[ -z "$failed_step" ]]; then
        err=$(iscsiadm -m node -T "$TARGET_IQN" -p "$portal_spec" -I "$iface" \
              --op=update -n node.session.auth.password -v "$CHAP_PASS" 2>&1) \
            || failed_step="password"
    fi

    if [[ -n "$failed_step" ]]; then
        ui_check "CHAP $iface → $portal" fail "step=$failed_step"
        local line
        while IFS= read -r line; do
            [[ -n "$line" ]] && ui_info "iscsiadm: $line"
        done <<<"$err"
        log "CHAP $failed_step failed on $iface → $portal_spec: $err"
        return 1
    fi
    ui_check "CHAP $iface → $portal" ok
    return 0
}

# Interleaved login + CHAP per iface, matching the manual procedure literally:
#
#   for each iface:
#       iscsiadm -m node -l -I iface_X         (generic iface login)
#       (if CHAP)  --op=update authmethod/username/password for each portal
#
# Then — and this step is NOT in the WITH-CHAP block of the manual procedure,
# but IS in the WITHOUT-CHAP block — explicit per-portal --login. We do it in
# both cases so a CHAP-required target ends up with a live authenticated
# session (the initial iface-wide login would have failed because credentials
# weren't set yet; the autostart setting that comes after would only kick in
# on reboot otherwise).
apply_login_and_chap() {
    local ifaces
    read -ra ifaces <<<"$ISCSI_IFACES"
    local i portal

    # Per-iface: generic login, then (optionally) set CHAP creds for each portal
    for (( i=0; i<${#ifaces[@]}; i++ )); do
        local iface="${ifaces[i]}"

        if iscsiadm -m session -P 1 2>/dev/null | grep -q "Iface Name: ${iface}\$"; then
            ui_check "login $iface (initial)" ok "session already up"
        else
            local err
            if err=$(iscsiadm -m node -l -I "$iface" 2>&1); then
                ui_check "login $iface (initial)" ok
            else
                if [[ "$USE_CHAP" == "yes" ]]; then
                    ui_check "login $iface (initial)" warn "expected — CHAP not set yet"
                else
                    ui_check "login $iface (initial)" warn "will retry per-portal"
                fi
                log "initial -l -I $iface: $err"
            fi
        fi

        if [[ "$USE_CHAP" == "yes" ]]; then
            for portal in $TARGET_PORTALS; do
                set_chap_record "$iface" "$portal" \
                    || handle_partial_failure "CHAP set failed on $iface → $portal"
            done
        fi
    done

    # Explicit per-pair --login (final, authoritative). Iterates pairs so we
    # log in exactly the sessions we want — not the Cartesian product.
    local pair
    for pair in $NIC_PORTAL_PAIRS; do
        local iface="${pair%%:*}" portal="${pair#*:}"
        local err
        if err=$(iscsiadm -m node -T "$TARGET_IQN" -p "$portal" -I "$iface" --login 2>&1); then
            ui_check "login $iface → $portal" ok
        elif grep -qiE 'session.*exists|already (logged in|exist)|session requested.*already present' <<<"$err"; then
            ui_check "login $iface → $portal" ok "already logged in"
        else
            ui_check "login $iface → $portal" fail
            local line
            while IFS= read -r line; do
                [[ -n "$line" ]] && ui_info "iscsiadm: $line"
            done <<<"$err"
            log "login failed on $iface → $portal: $err"
            handle_partial_failure "login $iface → $portal failed"
        fi
    done
}

apply_autostart() {
    # Iterate pairs (with explicit -I iface) so we set node.startup=automatic
    # only on the records we own — never on other targets' records that
    # happen to share a portal IP.
    local pair
    for pair in $NIC_PORTAL_PAIRS; do
        local iface="${pair%%:*}" portal="${pair#*:}"
        if iscsiadm -m node -T "$TARGET_IQN" -p "$portal" -I "$iface" \
                --op update -n node.startup -v automatic >>"$LOG_FILE" 2>&1; then
            ui_check "node.startup=automatic ($iface → $portal)" ok
        else
            ui_check "node.startup=automatic ($iface → $portal)" warn "non-fatal"
        fi
    done
}

handle_partial_failure() {
    local reason="$1"
    case "$PARTIAL_PATH_POLICY" in
        continue) ui_warn "continuing: $reason" ;;
        abort)    ui_fail "aborting: $reason"; exit 10 ;;
        prompt)
            ui_warn "$reason"
            if (( OPT_NON_INTERACTIVE )); then
                ui_die "non-interactive + partial failure with policy=prompt"
            fi
            if ! ui_confirm "Continue with the working paths?" "n"; then
                ui_die "aborted by user"
            fi
            ;;
    esac
}

phase_apply() {
    ui_phase 3 4 "Apply"
    ui_step "Initiator name";  apply_initiator_name
    ui_step "Multipath";       apply_multipath_conf
    ui_step "iSCSI ifaces";    apply_ifaces
    ui_step "Discovery";       apply_discovery
    ui_step "Node records";    ensure_node_records
    ui_step "iSCSI tuning";    apply_iscsid_tuning
    ui_step "Login + CHAP";    apply_login_and_chap
    ui_step "Autostart";       apply_autostart
    ui_phase_end
}

# ----------------------------------------------------------------------------
# Phase 4 — Verify + report
# ----------------------------------------------------------------------------
phase_verify() {
    ui_phase 4 4 "Verify"

    ui_step "Sessions"
    local sessions; sessions=$(iscsiadm -m session 2>/dev/null || true)
    if [[ -n "$sessions" ]]; then
        local n; n=$(echo "$sessions" | wc -l)
        ui_check "active iSCSI sessions" ok "$n"
        while IFS= read -r line; do ui_info "$line"; done <<<"$sessions"
    else
        ui_check "active iSCSI sessions" fail "none"
    fi

    ui_step "Multipath map"
    sleep 2  # let device-mapper catch up
    multipath -r >/dev/null 2>&1 || true
    local mp; mp=$(multipath -ll 2>/dev/null || true)
    if [[ -n "$mp" ]]; then
        while IFS= read -r line; do ui_info "$line"; done <<<"$mp"
    else
        ui_warn "multipath -ll returned nothing yet (sometimes takes a few seconds)"
    fi

    ui_step "Block devices"
    while IFS= read -r line; do ui_info "$line"; done < <(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null)

    echo
    printf '  %sDiscovered LUNs (for the GFS2 GUI step)%s\n' "${C_BOLD}" "${C_RESET}"
    printf '  %s' "${C_DIM}"; printf '─%.0s' $(seq 1 70); printf '%s\n' "${C_RESET}"
    printf '  %-36s %-10s %s\n' "WWID / mpath device" "Size" "Underlying paths"
    printf '  %s' "${C_DIM}"; printf '─%.0s' $(seq 1 70); printf '%s\n' "${C_RESET}"
    # parse multipath output
    if command -v multipath >/dev/null 2>&1; then
        local wwid size paths
        while read -r ln; do
            # mpath header line looks like:   mpathb (3600140589abcdef0) dm-3 QNAP    ,iSCSI Storage
            if [[ "$ln" =~ ^([a-zA-Z0-9_-]+)\ \(([^\)]+)\)\ dm- ]]; then
                wwid="${BASH_REMATCH[2]}"
                # find the device name to get its size
                local dev="/dev/mapper/${BASH_REMATCH[1]}"
                size=$(lsblk -dn -o SIZE "$dev" 2>/dev/null | tr -d ' ' || echo "?")
                paths=$(multipath -ll "$dev" 2>/dev/null | grep -oE 'sd[a-z]+' | paste -sd, -)
                printf '  %-36s %-10s %s\n' "$wwid" "$size" "$paths"
            fi
        done <<<"$mp"
    fi
    printf '  %s' "${C_DIM}"; printf '─%.0s' $(seq 1 70); printf '%s\n' "${C_RESET}"

    ui_step "Persistence (reboot survival)"
    local persist_ok=1
    if systemctl is-enabled --quiet iscsid 2>/dev/null; then
        ui_check "iscsid enabled at boot" ok
    else
        ui_check "iscsid enabled at boot" fail; persist_ok=0
    fi
    if systemctl is-enabled --quiet multipathd 2>/dev/null; then
        ui_check "multipathd enabled at boot" ok
    else
        ui_check "multipathd enabled at boot" fail; persist_ok=0
    fi
    if systemctl is-enabled --quiet "$AUTOLOGIN_SVC" 2>/dev/null; then
        ui_check "$AUTOLOGIN_SVC enabled at boot (auto-login)" ok
    else
        ui_check "$AUTOLOGIN_SVC enabled at boot (auto-login)" fail
        persist_ok=0
    fi
    # Count node records with node.startup=automatic — iterate pairs, not Cartesian
    local auto_count=0
    local pair startup
    for pair in $NIC_PORTAL_PAIRS; do
        local iface="${pair%%:*}" portal="${pair#*:}"
        startup=$(iscsiadm -m node -T "$TARGET_IQN" -p "$portal" -I "$iface" --op=show 2>/dev/null \
            | awk -F'=' '$1 ~ /node\.startup[[:space:]]*$/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}' \
            | head -1)
        [[ "$startup" == "automatic" ]] && (( auto_count++ ))
    done
    if (( auto_count > 0 )); then
        ui_check "node.startup=automatic" ok "$auto_count record(s)"
    else
        ui_check "node.startup=automatic" fail "no node records set to automatic"
        persist_ok=0
    fi
    if (( persist_ok )); then
        ui_ok "reboot persistence verified — sessions will auto-restore"
    else
        ui_warn "reboot persistence incomplete — see failures above"
    fi

    ui_phase_end

    echo
    printf '  %sDone.%s  Log: %s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}" "$LOG_FILE"
    printf '  Next step:  add GFS2 cluster storage in the Morpheus GUI using\n'
    printf '              the WWID(s) above (Storage → Storage → + Add Storage).\n\n'
}

# ----------------------------------------------------------------------------
# SSH multi-host wrapper
# ----------------------------------------------------------------------------
run_remote() {
    local hosts_csv="$1"
    IFS=',' read -ra hosts <<<"$hosts_csv"

    ui_banner
    ui_step "Remote sweep across ${#hosts[@]} host(s)"
    ui_info "${hosts[*]}"
    echo

    # Ensure we have a config file to ship; without one we can't run non-interactively over SSH safely.
    local cfg="$OPT_CONFIG"
    [[ -z "$cfg" ]] && [[ -r ./iscsi-setup.conf ]] && cfg="./iscsi-setup.conf"
    if [[ -z "$cfg" ]]; then
        ui_die "remote mode requires --config FILE (cannot prompt over SSH)"
    fi
    [[ ! -r "$cfg" ]] && ui_die "config not readable: $cfg"

    local failed=()
    local h
    for h in "${hosts[@]}"; do
        echo
        printf '%s═══ %s ═══════════════════════════════════════════════════════%s\n' "${C_CYAN}" "$h" "${C_RESET}"
        if ! scp -q -o BatchMode=yes "$SCRIPT_PATH" "${h}:/tmp/${SCRIPT_NAME}.sh"; then
            ui_fail "$h: scp script failed"; failed+=("$h"); continue
        fi
        if ! scp -q -o BatchMode=yes "$cfg" "${h}:/tmp/iscsi-setup.conf"; then
            ui_fail "$h: scp config failed"; failed+=("$h"); continue
        fi
        ssh -o BatchMode=yes "$h" "chmod 600 /tmp/iscsi-setup.conf && chmod +x /tmp/${SCRIPT_NAME}.sh"
        if ssh -t -o BatchMode=yes "$h" \
            "sudo /tmp/${SCRIPT_NAME}.sh --config /tmp/iscsi-setup.conf --non-interactive"; then
            ui_ok "$h: completed"
        else
            ui_fail "$h: setup failed"; failed+=("$h")
        fi
        ssh -o BatchMode=yes "$h" "rm -f /tmp/${SCRIPT_NAME}.sh /tmp/iscsi-setup.conf" || true
    done

    echo
    if (( ${#failed[@]} )); then
        ui_fail "failures on: ${failed[*]}"
        exit 8
    fi
    ui_ok "all hosts completed successfully"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    parse_args "$@"
    init_colours

    if (( OPT_LIST_NICS )); then
        list_nics
        exit 0
    fi

    if [[ -n "$OPT_REMOTE_HOSTS" ]]; then
        run_remote "$OPT_REMOTE_HOSTS"
        exit 0
    fi

    require_root "$@"
    log_init
    log "started v${VERSION} on $(hostname -f 2>/dev/null || hostname) with args: $*"

    ui_banner
    detect_distro
    ui_info "host: $(hostname -f 2>/dev/null || hostname)   distro: $DISTRO_NAME"
    ui_info "log:  $LOG_FILE"

    ui_phase 1 4 "Configuration"
    load_config_file
    apply_env_overrides
    if (( OPT_NON_INTERACTIVE )); then
        # Validate required values are present
        for v in TARGET_IQN TARGET_PORTALS STORAGE_NICS EXPECTED_MTU; do
            [[ -z "${!v}" ]] && ui_die "non-interactive: $v is required in config"
        done
        # Derive ifaces if missing
        if [[ -z "$ISCSI_IFACES" ]]; then
            local s=""
            for n in $STORAGE_NICS; do s+="iface_${n} "; done
            ISCSI_IFACES="${s% }"
        fi
        [[ -z "$USE_CHAP" ]] && USE_CHAP="no"
        [[ -z "$SET_INITIATOR_NAME" ]] && SET_INITIATOR_NAME="no"
        [[ -z "$WRITE_MULTIPATH_CONF" ]] && WRITE_MULTIPATH_CONF="yes"
        [[ -z "$ISCSI_TUNING_PROFILE" ]] && ISCSI_TUNING_PROFILE="default"
        if [[ "$ISCSI_TUNING_PROFILE" == "custom" ]]; then
            [[ -z "$ISCSI_CMDS_MAX" || -z "$ISCSI_QUEUE_DEPTH" ]] \
                && ui_die "non-interactive + custom tuning requires ISCSI_CMDS_MAX and ISCSI_QUEUE_DEPTH"
        fi
        if [[ "$USE_CHAP" == "yes" ]]; then
            [[ -z "$CHAP_USER" || -z "$CHAP_PASS" ]] && ui_die "non-interactive: CHAP enabled but credentials missing"
        fi
    else
        interactive_fill
    fi
    derive_nic_portal_pairs
    ui_phase_end

    show_summary
    preflight
    phase_apply
    phase_verify
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
