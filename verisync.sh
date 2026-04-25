#!/bin/bash
# verisync — General-purpose interactive directory transfer with checksum verify
#              Supports BATCH mode: transfer multiple sources in one SSH session.
#
# Usage:
#   verisync [OPTIONS]            Start a new transfer
#   verisync ls                   List active verisync sessions across login nodes
#   verisync -r | --reattach      Pick an active session and reattach
#                                 (if it's on another login node, you'll be SSH'd
#                                 there; re-run `verisync -r` after 2FA login)
#
# Options:
#   -s, --src  <path>    Local source to transfer (repeat for batch, e.g. -s a -s b)
#   -u, --user <user>    Remote SSH username
#   -H, --host <host>    Remote SSH hostname / IP
#   -d, --dest <path>    Remote destination (1 shared dest OR one per --src, e.g. -d x -d y)
#       --zip            Pack each source into tar.gz before transferring (default: rsync)
#   -y, --yes            Auto-confirm all prompts (non-interactive / scripted mode)
#   -h, --help           Show this help and exit
#
# Destination rules:
#   • 1 --dest            → all sources land in the same remote directory
#   • N --dest (= N --src) → each source maps to its own remote directory (1:1)
#
# Any option not supplied on the command line will be prompted interactively.
# In interactive mode, enter sources/destinations one at a time; leave blank when done.
#
# Steps performed:
#   1. Collect source(s), destination(s) and target server details (CLI or prompt)
#   2. Measure total transfer size; warn if > 100 GiB
#   3. Test SSH connectivity and check remote free space (single session)
#   4. For each source: generate SHA-256 checksums
#   5. For each source: transfer files (and checksum manifest) via rsync
#   6. For each source: verify checksums on the remote side
#   7. Print batch summary (pass / fail per source)

set -euo pipefail

# ── Session marker (kept in shared $HOME so any login node can list them) ────
MARKER_DIR="$HOME/.verisync/sessions"
mkdir -p "$MARKER_DIR" 2>/dev/null
chmod 700 "$MARKER_DIR" 2>/dev/null

_marker_write() {
    # _marker_write <session> <wrapper> [remote] [sources_joined] [dests_joined]
    # Sources/dests are joined with $'\x1f' (Unit Separator) so spaces in paths are safe.
    local session="$1" wrapper="$2"
    local remote="${3:-}" sources="${4:-}" dests="${5:-}"
    local f="$MARKER_DIR/$session"
    cat > "$f" <<EOF
SESSION=$session
LOGIN_NODE=$(hostname -s)
START_TS=$(date +%s)
WRAPPER=$wrapper
REMOTE=$remote
SOURCES=$sources
DESTS=$dests
EOF
    chmod 600 "$f"
}

_marker_update_config() {
    # Re-write our own marker with config fields after Step 1 has parsed them.
    [ -z "${VERISYNC_MARKER:-}" ] && return 0
    local remote="$1" sources="$2" dests="$3"
    # Preserve original SESSION/WRAPPER/START_TS by reading them back first.
    local SESSION_KEEP="" WRAPPER_KEEP="" START_TS_KEEP=""
    if [ -f "$VERISYNC_MARKER" ]; then
        # shellcheck disable=SC1090
        ( source "$VERISYNC_MARKER"; \
          echo "$SESSION"; echo "$WRAPPER"; echo "$START_TS" ) > /tmp/.verisync_kv_$$
        { read -r SESSION_KEEP; read -r WRAPPER_KEEP; read -r START_TS_KEEP; } < /tmp/.verisync_kv_$$
        rm -f /tmp/.verisync_kv_$$
    fi
    cat > "$VERISYNC_MARKER" <<EOF
SESSION=$SESSION_KEEP
LOGIN_NODE=$(hostname -s)
START_TS=$START_TS_KEEP
WRAPPER=$WRAPPER_KEEP
REMOTE=$remote
SOURCES=$sources
DESTS=$dests
EOF
    chmod 600 "$VERISYNC_MARKER"
}

_marker_remove() {
    [ -n "${VERISYNC_MARKER:-}" ] && rm -f "$VERISYNC_MARKER" 2>/dev/null || true
}

_join_us() {
    # Join positional args with US (\x1f) — safe because Unix paths can't contain it.
    local IFS=$'\x1f'
    echo "$*"
}

_check_duplicate_session() {
    # _check_duplicate_session <my_session_name> <remote> <sources_joined> <dests_joined>
    # Returns 0 if no duplicate, otherwise prompts user.
    local my_sess="$1" my_remote="$2" my_sources="$3" my_dests="$4"
    shopt -s nullglob
    local files=("$MARKER_DIR"/*)
    shopt -u nullglob
    local match_session="" match_node=""
    for f in "${files[@]}"; do
        [ "$(basename "$f")" = "$my_sess" ] && continue
        unset SESSION LOGIN_NODE START_TS WRAPPER REMOTE SOURCES DESTS
        # shellcheck disable=SC1090
        source "$f" 2>/dev/null || continue
        # Skip if config not yet filled (other session still in Step 1)
        [ -z "${SOURCES:-}" ] && continue
        # Skip stale (no screen on its own node, can only check if same node)
        if [ "${LOGIN_NODE:-}" = "$(hostname -s)" ] \
           && ! screen -ls 2>/dev/null | grep -q "$SESSION"; then
            continue
        fi
        if [ "${REMOTE:-}" = "$my_remote" ] \
           && [ "${SOURCES:-}" = "$my_sources" ] \
           && [ "${DESTS:-}" = "$my_dests" ]; then
            match_session="$SESSION"
            match_node="$LOGIN_NODE"
            break
        fi
    done

    [ -z "$match_session" ] && return 0

    echo ""
    warn "Duplicate transfer already running:"
    warn "  session  : $match_session"
    warn "  on node  : $match_node"
    warn "  same remote=$my_remote, same sources, same destinations"
    echo ""

    if [ "${AUTO_YES:-false}" = true ]; then
        warn "--yes set: aborting current transfer to avoid clobbering the running one."
        die "Aborted (duplicate session $match_session already running on $match_node)."
    fi

    local prompt
    if [ "$match_node" = "$(hostname -s)" ]; then
        prompt="  Choose: (a)bort current / (k)ill other / (i)gnore and continue [a/k/i]: "
    else
        prompt="  Other session is on $match_node — can't kill it from here. Choose: (a)bort current / (i)gnore and continue [a/i]: "
    fi
    local choice
    read -rp "$prompt" choice
    case "$choice" in
        a|A|"")
            die "Aborted by user (duplicate of $match_session)." ;;
        k|K)
            if [ "$match_node" != "$(hostname -s)" ]; then
                die "Cannot kill remote session from here. Aborting."
            fi
            info "Killing screen session $match_session …"
            screen -X -S "$match_session" quit 2>/dev/null || warn "screen -X quit failed; you may need to clean up manually."
            rm -f "$MARKER_DIR/$match_session"
            ok "Other session terminated. Continuing with current transfer."
            ;;
        i|I)
            warn "Ignoring duplicate; proceeding (may clobber the other transfer)." ;;
        *)
            die "Invalid choice; aborting." ;;
    esac
    return 0
}

_verisync_list_or_attach() {
    # Mode: "ls" -> only print table, never attach.
    # Mode: "-r" -> print table, then prompt to reattach.
    local mode="$1"
    shopt -s nullglob
    local files=("$MARKER_DIR"/*)
    shopt -u nullglob
    if [ ${#files[@]} -eq 0 ]; then
        echo "No verisync sessions found in $MARKER_DIR"
        return 0
    fi

    printf "  %3s  %-32s  %-12s  %-10s  %s\n" "#" "SESSION" "LOGIN_NODE" "AGE" "STATUS"
    printf "  %3s  %-32s  %-12s  %-10s  %s\n" "---" "--------------------------------" "------------" "----------" "------"

    local i=0
    local -a vs_session=() vs_node=() vs_status=()
    local now=$(date +%s)
    for f in "${files[@]}"; do
        unset SESSION LOGIN_NODE START_TS WRAPPER
        # shellcheck disable=SC1090
        source "$f"
        local age_s=$(( now - ${START_TS:-0} ))
        local age_h
        age_h=$(printf '%dh%02dm' $((age_s/3600)) $(((age_s%3600)/60)))
        local status
        if [ "${LOGIN_NODE:-}" = "$(hostname -s)" ]; then
            if screen -ls 2>/dev/null | grep -q "$SESSION"; then
                status="alive"
            else
                status="stale"
            fi
        else
            status="remote"
        fi
        i=$((i+1))
        vs_session[$i]="${SESSION:-?}"
        vs_node[$i]="${LOGIN_NODE:-?}"
        vs_status[$i]="$status"
        printf "  %3d  %-32s  %-12s  %-10s  %s\n" "$i" "${SESSION:-?}" "${LOGIN_NODE:-?}" "$age_h" "$status"
    done
    echo ""

    # ls only: just print and bail
    [ "$mode" = "ls" ] && return 0

    [ ${#vs_session[@]} -eq 0 ] && return 0

    local choice
    if [ ${#vs_session[@]} -eq 1 ]; then
        echo "  Only one session — selecting #1 automatically."
        choice=1
    else
        read -rp "  Reattach to # (Enter or q to quit, p to prune stale): " choice
    fi

    if [[ "$choice" == "p" ]]; then
        local pruned=0
        for j in "${!vs_session[@]}"; do
            if [ "${vs_status[$j]}" = "stale" ]; then
                rm -f "$MARKER_DIR/${vs_session[$j]}" && {
                    echo "  pruned: ${vs_session[$j]}"
                    pruned=$((pruned+1))
                }
            fi
        done
        echo "  $pruned stale marker(s) removed."
        return 0
    fi
    [[ -z "$choice" || "$choice" == "q" ]] && return 0
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ -z "${vs_session[$choice]:-}" ]; then
        echo "  Invalid selection."
        return 1
    fi

    local sess="${vs_session[$choice]}"
    local node="${vs_node[$choice]}"
    local stat="${vs_status[$choice]}"

    if [ "$stat" = "stale" ]; then
        echo "  Session looks dead (no screen on this node) — removing marker."
        rm -f "$MARKER_DIR/$sess"
        return 0
    fi

    if [ "$node" = "$(hostname -s)" ]; then
        echo "  Reattaching to $sess on $node …"
        exec screen -r "$sess"
    else
        # Cross-node: ssh to that login node (likely triggers 2FA), then auto
        # `screen -r <session>` over there. If the screen session is gone by
        # the time we get there, drop to a login shell so the user isn't kicked.
        echo ""
        echo "  Session $sess is on a different login node ($node)."
        echo "  SSHing to $node and reattaching (2FA prompt likely)…"
        echo ""
        local target="${USER}@${node}"
        # Try .nchc.org.tw FQDN if short hostname doesn't resolve
        if ! getent hosts "$node" >/dev/null 2>&1; then
            target="${USER}@${node}.nchc.org.tw"
        fi
        # screen -r exits non-zero if the session is gone → fall back to login shell.
        exec ssh -t "$target" "screen -r '$sess' || { echo '[verisync] session not found on $node; dropping to shell.'; exec bash -l; }"
    fi
}

# ── Early dispatch: ls / reattach (handle before screen/tmux wrap) ──────────
case "${1:-}" in
    ls|--list)
        _verisync_list_or_attach ls
        exit 0 ;;
    -r|--reattach)
        _verisync_list_or_attach -r
        exit 0 ;;
esac

# ── Early help: handle before screen/tmux wrap ───────────────────────────────
for _arg in "$@"; do
    if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
        awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
        exit 0
    fi
done
unset _arg

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
hr()    { printf '%s\n' "$(printf '─%.0s' {1..60})"; }
info()  { echo -e "${BLUE}[•]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

# Pretty-print bytes as human-readable (works without numfmt)
human_bytes() {
    local b=$1
    if   (( b >= 1099511627776 )); then printf "%.1f TiB" "$(echo "scale=1; $b/1099511627776" | bc)"
    elif (( b >= 1073741824 ))   ; then printf "%.1f GiB" "$(echo "scale=1; $b/1073741824"    | bc)"
    elif (( b >= 1048576 ))      ; then printf "%.1f MiB" "$(echo "scale=1; $b/1048576"        | bc)"
    elif (( b >= 1024 ))         ; then printf "%.1f KiB" "$(echo "scale=1; $b/1024"           | bc)"
    else printf "%d B" "$b"
    fi
}

# Test hook: when sourced (not executed) with VERISYNC_TEST_LIB=1, stop here
# so test code can call internal functions (e.g. _check_duplicate_session)
# without running the main transfer flow. All helpers / marker fns are defined
# above this point so callers can use them.
if [ "${VERISYNC_TEST_LIB:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# ── Disconnect guard: auto-wrap inside screen ─────────────────────────────────
if [[ -z "${STY:-}" && -z "${TMUX:-}" ]]; then
    SCRIPT_ABS="$(realpath "$0")"
    # Include hostname in session name so two login nodes can't clash on PIDs
    SESSION="verisync_$(hostname -s)_$$"
    if command -v screen &>/dev/null; then
        _marker_write "$SESSION" "screen"
        export VERISYNC_MARKER="$MARKER_DIR/$SESSION"
        echo "[verisync] Wrapping inside screen session '${SESSION}' on $(hostname -s) ..."
        echo "[verisync] Re-attach (this node):  screen -r ${SESSION}"
        echo "[verisync] List/find from any login node:  verisync ls   /   verisync -r"
        sleep 1
        exec screen -S "$SESSION" bash "$SCRIPT_ABS" "$@"
    elif command -v tmux &>/dev/null; then
        _marker_write "$SESSION" "tmux"
        export VERISYNC_MARKER="$MARKER_DIR/$SESSION"
        echo "[verisync] Wrapping inside tmux session '${SESSION}' on $(hostname -s) ..."
        echo "[verisync] Re-attach (this node):  tmux attach -t ${SESSION}"
        echo "[verisync] List/find from any login node:  verisync ls   /   verisync -r"
        sleep 1
        exec tmux new-session -s "$SESSION" bash "$SCRIPT_ABS" "$@"
    else
        echo -e "\033[1;33m[!] screen/tmux not found — disconnect will kill the transfer.\033[0m"
        echo ""
    fi
fi

# Inside the wrapped shell: clean up our marker on any exit (success/fail/Ctrl-C).
# Note: this trap is augmented (not replaced) by the SSH-cleanup trap later.
trap '_marker_remove' EXIT

# ── Argument parsing ──────────────────────────────────────────────────────────
USE_ZIP=false
AUTO_YES=false
SRC_DIRS=()       # array — supports multiple --src values
DEST_DIRS=()      # array — 1 shared dest OR one per source
REMOTE_USER=""
REMOTE_HOST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--src)
            [[ -n "${2:-}" ]] || die "--src requires a value"
            SRC_DIRS+=("$2"); shift 2 ;;
        -u|--user)
            [[ -n "${2:-}" ]] || die "--user requires a value"
            REMOTE_USER="$2"; shift 2 ;;
        -H|--host)
            [[ -n "${2:-}" ]] || die "--host requires a value"
            REMOTE_HOST="$2"; shift 2 ;;
        -d|--dest)
            [[ -n "${2:-}" ]] || die "--dest requires a value"
            DEST_DIRS+=("$2"); shift 2 ;;
        --zip)
            USE_ZIP=true; shift ;;
        -y|--yes)
            AUTO_YES=true; shift ;;
        -h|--help)
            awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
        *) die "Unknown option: $1  (use --help for usage)" ;;
    esac
done

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
hr
echo "        Interactive Directory Transfer with Checksum Verify"
hr
echo -e "${NC}"
echo " Mode : $([ "$USE_ZIP" = true ] && echo 'tar.gz archive + transfer' || echo 'rsync (direct, resumable)')"
echo " Auto : $([ "$AUTO_YES" = true ] && echo 'YES — all confirmations skipped' || echo 'interactive')"
echo " Start: $(date)"
[[ -n "${STY:-}" ]] && echo " Screen: ${STY}  (re-attach: screen -r ${STY##*.})"
[[ -n "${TMUX:-}" ]] && echo " Tmux  : $(tmux display-message -p '#S' 2>/dev/null)  (re-attach: tmux attach -t $(tmux display-message -p '#S' 2>/dev/null))"
hr
echo ""

# ── Step 1 : Collect configuration ───────────────────────────────────────────
echo -e "${BOLD}[Step 1/6] Transfer Configuration${NC}"
echo ""

# Source(s) — prompt only if none supplied via CLI
if [ ${#SRC_DIRS[@]} -eq 0 ]; then
    echo "  Enter source files/directories one per line."
    echo "  Leave blank and press Enter when done."
    echo ""
    while true; do
        read -rp "  Source $(( ${#SRC_DIRS[@]} + 1 )) (blank to finish): " _raw
        [[ -z "$_raw" ]] && { [ ${#SRC_DIRS[@]} -gt 0 ] && break || { error "Enter at least one source."; continue; }; }
        _raw="${_raw%/}"
        _raw="${_raw/#\~/$HOME}"
        if { [ -d "$_raw" ] || [ -f "$_raw" ]; }; then
            SRC_DIRS+=("$_raw")
            ok "  Added: $_raw"
        else
            error "Not found: $_raw"
        fi
    done
else
    # Normalise paths supplied via CLI
    _normalized=()
    for _p in "${SRC_DIRS[@]}"; do
        _p="${_p%/}"
        _p="${_p/#\~/$HOME}"
        { [ -d "$_p" ] || [ -f "$_p" ]; } || die "Source not found: $_p"
        _normalized+=("$_p")
    done
    SRC_DIRS=("${_normalized[@]}")
fi

BATCH_TOTAL=${#SRC_DIRS[@]}
echo ""
echo "  ${BATCH_TOTAL} source(s) queued:"
for _s in "${SRC_DIRS[@]}"; do echo "    • $_s"; done
echo ""

# Remote username
if [ -z "$REMOTE_USER" ]; then
    read -rp "  Remote username  : " REMOTE_USER
fi

# Remote hostname
if [ -z "$REMOTE_HOST" ]; then
    read -rp "  Remote hostname  : " REMOTE_HOST
fi

# Destination(s) — prompt only if none supplied via CLI
if [ ${#DEST_DIRS[@]} -eq 0 ]; then
    echo ""
    echo "  Enter remote destination(s)."
    echo "  Enter 1 directory to use the same dest for all sources,"
    echo "  or enter one per source (${BATCH_TOTAL} total). Leave blank when done."
    echo ""
    while true; do
        read -rp "  Dest $(( ${#DEST_DIRS[@]} + 1 )) (blank to finish): " _raw
        if [[ -z "$_raw" ]]; then
            [ ${#DEST_DIRS[@]} -gt 0 ] && break
            error "Enter at least one destination."
            continue
        fi
        DEST_DIRS+=("${_raw%/}")
        ok "  Added: ${_raw%/}"
        # stop automatically once we match source count
        [ ${#DEST_DIRS[@]} -eq "$BATCH_TOTAL" ] && break
    done
else
    # Normalise trailing slashes
    _dnorm=()
    for _p in "${DEST_DIRS[@]}"; do _dnorm+=("${_p%/}"); done
    DEST_DIRS=("${_dnorm[@]}")
fi

# Validate mapping
if [ ${#DEST_DIRS[@]} -eq 1 ]; then
    # Broadcast: replicate the single dest for every source
    _single_dest="${DEST_DIRS[0]}"
    DEST_DIRS=()
    for _i in $(seq 1 "$BATCH_TOTAL"); do DEST_DIRS+=("$_single_dest"); done
elif [ ${#DEST_DIRS[@]} -ne "$BATCH_TOTAL" ]; then
    die "Destination count (${#DEST_DIRS[@]}) must be 1 (shared) or equal to source count (${BATCH_TOTAL})."
fi

echo ""
echo -e "  ${BOLD}Source → Destination mapping:${NC}"
for _i in "${!SRC_DIRS[@]}"; do
    printf "    %-45s → %s@%s:%s\n" "${SRC_DIRS[$_i]}" "$REMOTE_USER" "$REMOTE_HOST" "${DEST_DIRS[$_i]}"
done
echo ""

# Update our marker with parsed config so other invocations can detect duplicates
_REMOTE_FP="${REMOTE_USER}@${REMOTE_HOST}"
# Sort sources/dests as ordered pairs so order doesn't matter for dup detection.
# Build "src\x1fdest" lines, sort, then re-flatten.
_PAIRS=()
for _i in "${!SRC_DIRS[@]}"; do
    _PAIRS+=("${SRC_DIRS[$_i]}"$'\x1f'"${DEST_DIRS[$_i]}")
done
IFS=$'\n' read -r -d '' -a _PAIRS_SORTED < <(printf '%s\n' "${_PAIRS[@]}" | sort && printf '\0') || true
_SOURCES_FP=""
_DESTS_FP=""
for _p in "${_PAIRS_SORTED[@]}"; do
    _src="${_p%$'\x1f'*}"
    _dst="${_p#*$'\x1f'}"
    _SOURCES_FP+="${_src}"$'\x1f'
    _DESTS_FP+="${_dst}"$'\x1f'
done
_SOURCES_FP="${_SOURCES_FP%$'\x1f'}"
_DESTS_FP="${_DESTS_FP%$'\x1f'}"

if [ -n "${VERISYNC_MARKER:-}" ]; then
    _MY_SESSION_NAME="$(basename "$VERISYNC_MARKER")"
    _marker_update_config "$_REMOTE_FP" "$_SOURCES_FP" "$_DESTS_FP"
    _check_duplicate_session "$_MY_SESSION_NAME" "$_REMOTE_FP" "$_SOURCES_FP" "$_DESTS_FP"
fi
unset _PAIRS _PAIRS_SORTED _REMOTE_FP _SOURCES_FP _DESTS_FP _MY_SESSION_NAME

# SSH multiplexing — shared across the whole batch
SSH_CTRL="/tmp/ssh_transfer_$$"
SSH_OPTS="-o ControlMaster=auto -o ControlPath=${SSH_CTRL} -o ControlPersist=24h -o ServerAliveInterval=60 -o ServerAliveCountMax=10"
trap '_marker_remove; ssh -o ControlPath="${SSH_CTRL}" -O exit "${REMOTE_USER}@${REMOTE_HOST}" 2>/dev/null; rm -f /tmp/transfer_*_$$.sha256 /tmp/transfer_*_$$.tar.gz "$SSH_CTRL" 2>/dev/null' EXIT

# ── Step 2 : Aggregate local size analysis ────────────────────────────────────
echo -e "${BOLD}[Step 2/6] Measuring Total Source Size${NC}"
echo ""

TOTAL_BYTES=0
TOTAL_FILES=0
for _i in "${!SRC_DIRS[@]}"; do
    _s="${SRC_DIRS[$_i]}"
    _d="${DEST_DIRS[$_i]}"
    _bytes=$(du -sb "$_s" | awk '{print $1}')
    if [ -f "$_s" ]; then
        _files=1
    else
        _files=$(find "$_s" -type f | wc -l)
    fi
    _human=$(human_bytes "$_bytes")
    printf "  %-45s → %-30s  %6d file(s)  %s\n" "$(basename "$_s")" "$_d" "$_files" "$_human"
    (( TOTAL_BYTES += _bytes )) || true
    (( TOTAL_FILES += _files )) || true
done

TOTAL_HUMAN=$(human_bytes "$TOTAL_BYTES")
echo ""
echo "  Total  : ${TOTAL_FILES} file(s)   ${TOTAL_HUMAN}  (${TOTAL_BYTES} bytes)"
echo ""

# Warn if > 100 GiB
LIMIT_BYTES=107374182400   # 100 GiB
if (( TOTAL_BYTES > LIMIT_BYTES )); then
    warn "Total size exceeds ${BOLD}100 GiB${NC}."
    warn "Please verify you have sufficient quota on the target server before continuing."
    echo ""
    if [ "$AUTO_YES" = true ]; then
        warn "--yes set: skipping confirmation."
    else
        read -rp "  Continue anyway? [y/N] " CONFIRM_SIZE
        [[ "$CONFIRM_SIZE" =~ ^[Yy]$ ]] || die "Aborted by user."
    fi
    echo ""
fi

# ── Step 3 : SSH connectivity + remote disk space ─────────────────────────────
echo -e "${BOLD}[Step 3/6] Checking Target Server${NC}"
echo ""

info "Testing SSH connection to ${REMOTE_HOST} …"
info "(2FA / password prompt will appear here if required)"
if ! ssh ${SSH_OPTS} -o ConnectTimeout=30 "${REMOTE_USER}@${REMOTE_HOST}" exit; then
    die "SSH connection failed.  Check credentials and that the host is reachable."
fi
ok "SSH connection OK"
echo ""

# Remote free space — check each unique destination, walking up to the first
# existing ancestor so df never receives a non-existent path (which would
# return empty and incorrectly show 0 B free space).
info "Checking remote disk space …"
declare -A _CHECKED_MOUNTS
for _d in "${DEST_DIRS[@]}"; do
    # Find the deepest ancestor that already exists on the remote
    _existing=$(ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" "
        p=\"${_d}\"
        while [ -n \"\$p\" ] && [ \"\$p\" != '/' ]; do
            [ -e \"\$p\" ] && { echo \"\$p\"; exit 0; }
            p=\$(dirname \"\$p\")
        done
        echo '/'
    ")
    [ "${_CHECKED_MOUNTS[$_existing]+set}" = "set" ] && continue
    _CHECKED_MOUNTS[$_existing]=1
    _free_raw=$(ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" \
        "df -B1 \"${_existing}\" 2>/dev/null | awk 'NR==2{print \$4}'" || echo "0")
    _free_raw="${_free_raw//[^0-9]/}"
    _free_raw="${_free_raw:-0}"
    printf "  %-40s free space: %s  (df anchor: %s)\n" "${_d}" "$(human_bytes "$_free_raw")" "${_existing}"
    if (( _free_raw == 0 )); then
        warn "Could not determine free space for ${_d} — proceeding with caution."
    elif (( TOTAL_BYTES > _free_raw )); then
        warn "Total source size (${TOTAL_HUMAN}) may exceed free space ($(human_bytes "$_free_raw")) at ${_existing}!"
        if [ "$AUTO_YES" = true ]; then
            warn "--yes set: skipping confirmation."
        else
            read -rp "  Continue anyway? [y/N] " CONFIRM_SPACE
            [[ "$CONFIRM_SPACE" =~ ^[Yy]$ ]] || die "Aborted by user."
        fi
    fi
done
unset _CHECKED_MOUNTS

# Create all remote destination directories
info "Creating remote destination directories …"
for _d in "${DEST_DIRS[@]}"; do
    ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '${_d}'"
done
ok "Remote directories ready"
echo ""

# Final confirmation before starting the long operations
hr
echo ""
echo -e "  ${BOLD}Ready to proceed:${NC}"
printf "  %-45s  %s\n" "Source" "Remote destination"
printf "  %-45s  %s\n" "$(printf '─%.0s' {1..45})" "$(printf '─%.0s' {1..35})"
for _i in "${!SRC_DIRS[@]}"; do
    printf "  %-45s  %s@%s:%s\n" "${SRC_DIRS[$_i]}" "$REMOTE_USER" "$REMOTE_HOST" "${DEST_DIRS[$_i]}"
done
echo ""
echo "    Total   : ${TOTAL_HUMAN}  (${TOTAL_FILES} files)"
echo "    Mode    : $([ "$USE_ZIP" = true ] && echo 'zip then transfer' || echo 'rsync direct')"
echo ""
if [ "$AUTO_YES" = true ]; then
    ok "--yes set: starting transfer automatically."
else
    read -rp "  Start batch transfer now? [y/N] " CONFIRM_GO
    [[ "$CONFIRM_GO" =~ ^[Yy]$ ]] || die "Aborted by user."
fi
echo ""

TRANSFER_START=$(date +%s)
BATCH_PASSED=0
BATCH_FAILED=0
declare -a BATCH_RESULT_NAMES=()
declare -a BATCH_RESULT_STATUS=()
declare -a BATCH_RESULT_LOGS=()

# ══════════════════════════════════════════════════════════════════════════════
# Per-source loop — Steps 4, 5, 6
# ══════════════════════════════════════════════════════════════════════════════
for SRC_JOB_IDX in "${!SRC_DIRS[@]}"; do
    SRC_DIR="${SRC_DIRS[$SRC_JOB_IDX]}"
    REMOTE_DIR="${DEST_DIRS[$SRC_JOB_IDX]}"
    SRC_JOB_NUM=$(( SRC_JOB_IDX + 1 ))

    # Detect source type
    if [ -f "$SRC_DIR" ]; then IS_FILE=true; else IS_FILE=false; fi
    SRC_NAME=$(basename "$SRC_DIR")
    CHECKSUM_FILE="/tmp/transfer_${SRC_NAME}_$$.sha256"

    SRC_BYTES=$(du -sb "$SRC_DIR" | awk '{print $1}')
    if [ "$IS_FILE" = true ]; then SRC_FILES=1; else SRC_FILES=$(find "$SRC_DIR" -type f | wc -l); fi

    echo ""
    hr
    echo -e "${BOLD}  Source ${SRC_JOB_NUM}/${BATCH_TOTAL}: ${SRC_DIR}${NC}"
    echo -e "  Type: $([ "$IS_FILE" = true ] && echo 'file' || echo 'directory')   Files: ${SRC_FILES}   Size: $(human_bytes "$SRC_BYTES")"
    hr
    echo ""

    # ── Step 4 : Generate SHA-256 checksums ───────────────────────────────────
    echo -e "${BOLD}[Step 4/6] Generating SHA-256 Checksums  [${SRC_JOB_NUM}/${BATCH_TOTAL}]${NC}"
    echo ""
    info "Hashing ${SRC_FILES} file(s) …"
    echo ""

    true > "$CHECKSUM_FILE"   # ensure file exists and is empty

    if [ "$IS_FILE" = true ]; then
        printf "  [1/1] %s\n" "$(basename "$SRC_DIR")"
        sha256sum "$SRC_DIR" >> "$CHECKSUM_FILE"
    else
        HASH_IDX=0
        PAD=${#SRC_FILES}   # width of the total number for alignment
        TERM_COLS=$(tput cols 2>/dev/null || echo 80)
        while IFS= read -r -d '' filepath; do
            (( HASH_IDX++ )) || true
            label=$(printf "  [%${PAD}d/%d] %s" "$HASH_IDX" "$SRC_FILES" "$(basename "$filepath")")
            # Truncate to terminal width and pad with spaces to erase leftover chars
            printf "\r%-${TERM_COLS}s" "${label:0:$TERM_COLS}"
            sha256sum "$filepath" >> "$CHECKSUM_FILE"
        done < <(find "$SRC_DIR" -type f -print0 | sort -z)
        printf "\r%-${TERM_COLS}s\r" ""   # clear line
        echo ""
    fi

    CHECKSUM_COUNT=$(wc -l < "$CHECKSUM_FILE")
    echo ""
    ok "${CHECKSUM_COUNT} checksum(s) written to $(basename "$CHECKSUM_FILE")"
    echo ""

    # ── Step 5 : Transfer ─────────────────────────────────────────────────────
    echo -e "${BOLD}[Step 5/6] Transferring Files  [${SRC_JOB_NUM}/${BATCH_TOTAL}]${NC}"
    echo ""

    REMOTE_CHECKSUM="${REMOTE_DIR}/$(basename "$CHECKSUM_FILE")"

    if [ "$USE_ZIP" = true ]; then
        # ── Zip mode ──
        ARCHIVE="${CHECKSUM_FILE%.sha256}.tar.gz"
        info "Creating archive: $(basename "$ARCHIVE") …"
        tar -czf "$ARCHIVE" -C "$(dirname "$SRC_DIR")" "$SRC_NAME"
        ARCHIVE_SIZE=$(human_bytes "$(stat -c%s "$ARCHIVE")")
        ok "Archive created: $ARCHIVE_SIZE"
        echo ""

        info "Uploading archive …"
        rsync -avz --partial --progress \
            -e "ssh ${SSH_OPTS}" \
            "$ARCHIVE" \
            "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"
        echo ""

        info "Uploading checksum manifest …"
        rsync -avz \
            -e "ssh ${SSH_OPTS}" \
            "$CHECKSUM_FILE" \
            "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_CHECKSUM}"
        echo ""

        ok "Archive + checksum uploaded"
        echo ""

        # Remote extract
        info "Extracting archive on remote …"
        ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" \
            "cd '${REMOTE_DIR}' && tar -xzf '$(basename "$ARCHIVE")' && rm -f '$(basename "$ARCHIVE")'"
        ok "Remote extraction complete"
        echo ""

    else
        # ── rsync mode ──
        if [ "$IS_FILE" = true ]; then
            info "Rsyncing file ${SRC_NAME} …"
            rsync -avz --partial --progress \
                -e "ssh ${SSH_OPTS}" \
                "${SRC_DIR}" \
                "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"
        else
            info "Rsyncing directory ${SRC_NAME}/ …"
            rsync -avz --partial --progress \
                -e "ssh ${SSH_OPTS}" \
                "${SRC_DIR}/" \
                "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/${SRC_NAME}/"
        fi
        echo ""

        info "Uploading checksum manifest …"
        rsync -avz \
            -e "ssh ${SSH_OPTS}" \
            "$CHECKSUM_FILE" \
            "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_CHECKSUM}"
        echo ""

        ok "Files + checksum uploaded"
        echo ""
    fi

    # ── Step 6 : Checksum verification on remote ──────────────────────────────
    echo -e "${BOLD}[Step 6/6] Verifying Checksums on Remote  [${SRC_JOB_NUM}/${BATCH_TOTAL}]${NC}"
    echo ""
    info "Running sha256sum --check on remote …"
    echo ""

    # Build the remote verification script.
    # We rewrite absolute local paths → remote destination paths in the manifest.
    VERIFY_SCRIPT=$(cat <<PYEOF
#!/bin/bash
set -euo pipefail
MANIFEST="${REMOTE_CHECKSUM}"
REMOTE_DIR="${REMOTE_DIR}"
SRC_DIR="${SRC_DIR}"
SRC_NAME="${SRC_NAME}"
USE_ZIP="${USE_ZIP}"
IS_FILE="${IS_FILE}"
LOG_FILE="${REMOTE_DIR}/verify_${SRC_NAME}_$(date +%Y%m%d_%H%M%S).log"

PASSED=0
FAILED=0
MISSING=0

# Write log header
{
    echo "verisync — SHA-256 Verification Report"
    echo "Generated : \$(date)"
    echo "Manifest  : \$MANIFEST"
    echo "Target dir: \$REMOTE_DIR"
    echo "Source    : \$SRC_NAME"
    echo "────────────────────────────────────────────────────────────"
} > "\$LOG_FILE"

while IFS='  ' read -r hash filepath; do
    # Map local absolute path → remote absolute path
    if [ "\$IS_FILE" = "true" ]; then
        remote_file="\$REMOTE_DIR/\$SRC_NAME"
    elif [ "\$USE_ZIP" = "true" ]; then
        rel="\${filepath#\$SRC_DIR/}"
        remote_file="\$REMOTE_DIR/\$SRC_NAME/\$rel"
    else
        rel="\${filepath#\$SRC_DIR/}"
        remote_file="\$REMOTE_DIR/\$SRC_NAME/\$rel"
    fi

    if [ ! -f "\$remote_file" ]; then
        echo "  MISSING : \$remote_file"
        echo "MISSING : \$remote_file" >> "\$LOG_FILE"
        (( MISSING++ )) || true
        (( FAILED++  )) || true
        continue
    fi

    actual_hash=\$(sha256sum "\$remote_file" | awk '{print \$1}')
    if [ "\$hash" = "\$actual_hash" ]; then
        echo "OK      : \$remote_file" >> "\$LOG_FILE"
        (( PASSED++ )) || true
    else
        echo "  MISMATCH: \$remote_file"
        echo "MISMATCH: \$remote_file" >> "\$LOG_FILE"
        echo "  expected: \$hash" >> "\$LOG_FILE"
        echo "  actual  : \$actual_hash" >> "\$LOG_FILE"
        (( FAILED++ )) || true
    fi
done < "\$MANIFEST"

# Write log footer
{
    echo "────────────────────────────────────────────────────────────"
    echo "Passed  : \$PASSED"
    echo "Failed  : \$FAILED  (missing: \$MISSING)"
    if [ \$FAILED -eq 0 ]; then
        echo "Result  : SUCCESS — all checksums match"
    else
        echo "Result  : FAILED — see entries above"
    fi
    echo "────────────────────────────────────────────────────────────"
} >> "\$LOG_FILE"

echo ""
echo "Verification complete"
echo "  Passed : \$PASSED"
echo "  Failed : \$FAILED  (missing: \$MISSING)"
echo "  Log    : \$LOG_FILE"
if [ \$FAILED -eq 0 ]; then
    echo "STATUS=OK"
else
    echo "STATUS=FAIL"
fi
echo "LOGFILE=\$LOG_FILE"
PYEOF
)

    VERIFY_OUTPUT=$(ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" "bash -s" <<< "$VERIFY_SCRIPT" 2>&1)
    echo "$VERIFY_OUTPUT" | grep -v '^LOGFILE=' | sed 's/^/  /'
    REMOTE_LOG=$(echo "$VERIFY_OUTPUT" | grep '^LOGFILE=' | cut -d= -f2-)
    echo ""

    BATCH_RESULT_NAMES+=("$SRC_NAME")
    BATCH_RESULT_LOGS+=("${REMOTE_LOG:-}")
    if echo "$VERIFY_OUTPUT" | grep -q "STATUS=OK"; then
        BATCH_RESULT_STATUS+=("OK")
        (( BATCH_PASSED++ )) || true
    else
        BATCH_RESULT_STATUS+=("FAIL")
        (( BATCH_FAILED++ )) || true
    fi

    # Clean up local checksum/archive for this source
    rm -f "$CHECKSUM_FILE" "${CHECKSUM_FILE%.sha256}.tar.gz" 2>/dev/null || true

done   # ── end per-source loop ────────────────────────────────────────────────

# ── Batch summary ─────────────────────────────────────────────────────────────
TRANSFER_END=$(date +%s)
ELAPSED=$(( TRANSFER_END - TRANSFER_START ))
ELAPSED_STR=$(printf '%02dh %02dm %02ds' $(( ELAPSED/3600 )) $(( (ELAPSED%3600)/60 )) $(( ELAPSED%60 )))

echo ""
hr
echo ""
echo -e "${BOLD}  BATCH SUMMARY${NC}"
echo ""
printf "  %-40s  %-6s  %s\n" "Source" "Result" "Remote log"
printf "  %-40s  %-6s  %s\n" "$(printf '─%.0s' {1..40})" "──────" "──────────"
for _i in "${!BATCH_RESULT_NAMES[@]}"; do
    _name="${BATCH_RESULT_NAMES[$_i]}"
    _status="${BATCH_RESULT_STATUS[$_i]}"
    _log="${BATCH_RESULT_LOGS[$_i]}"
    if [ "$_status" = "OK" ]; then
        _col="${GREEN}"
    else
        _col="${RED}"
    fi
    printf "  %-40s  ${_col}%-6s${NC}  %s\n" "$_name" "$_status" "${_log:-—}"
done
echo ""

if (( BATCH_FAILED == 0 )); then
    echo -e "${GREEN}${BOLD}  ✓  ALL TRANSFERS SUCCESSFUL (${BATCH_PASSED}/${BATCH_TOTAL})${NC}"
else
    echo -e "${RED}${BOLD}  ✗  ${BATCH_FAILED} OF ${BATCH_TOTAL} TRANSFER(S) FAILED${NC}"
    echo ""
    echo "  To retry failed sources, re-run this script with only those --src paths."
    echo "  (rsync will skip already-complete files)"
fi
echo ""
echo "  Elapsed  : $ELAPSED_STR"
echo "  Finished : $(date)"
echo ""
hr
echo ""
[ "$AUTO_YES" = false ] && read -rp "  Press Enter to exit …" _
