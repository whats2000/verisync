#!/bin/bash
# verisync.sh — General-purpose interactive directory transfer with checksum verify
#              Supports BATCH mode: transfer multiple sources in one SSH session.
#
# Usage:
#   bash verisync.sh [OPTIONS]
#
# Options:
#   -s, --src  <path>    Local source to transfer (repeat for batch, e.g. -s a -s b)
#   -u, --user <user>    Remote SSH username
#   -H, --host <host>    Remote SSH hostname / IP
#   -d, --dest <path>    Remote destination (1 shared dest OR one per --src, e.g. -d x -d y)
#       --zip            Pack each source into tar.gz before transferring (default: rsync)
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

# ── Disconnect guard: auto-wrap inside screen ─────────────────────────────────
if [[ -z "${STY:-}" && -z "${TMUX:-}" ]]; then
    SCRIPT_ABS="$(realpath "$0")"
    SESSION="verisync_$$"
    if command -v screen &>/dev/null; then
        echo "[verisync] Wrapping inside screen session '${SESSION}' ..."
        echo "[verisync] Re-attach if disconnected:  screen -r ${SESSION}"
        sleep 1
        exec screen -S "$SESSION" bash "$SCRIPT_ABS" "$@"
    elif command -v tmux &>/dev/null; then
        echo "[verisync] Wrapping inside tmux session '${SESSION}' ..."
        echo "[verisync] Re-attach if disconnected:  tmux attach -t ${SESSION}"
        sleep 1
        exec tmux new-session -s "$SESSION" bash "$SCRIPT_ABS" "$@"
    else
        echo -e "\033[1;33m[!] screen/tmux not found — disconnect will kill the transfer.\033[0m"
        echo ""
    fi
fi

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

# ── Argument parsing ──────────────────────────────────────────────────────────
USE_ZIP=false
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
        -h|--help)
            grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
            exit 0 ;;
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

# SSH multiplexing — shared across the whole batch
SSH_CTRL="/tmp/ssh_transfer_$$"
SSH_OPTS="-o ControlMaster=auto -o ControlPath=${SSH_CTRL} -o ControlPersist=24h -o ServerAliveInterval=60 -o ServerAliveCountMax=10"
trap 'ssh -o ControlPath="${SSH_CTRL}" -O exit "${REMOTE_USER}@${REMOTE_HOST}" 2>/dev/null; rm -f /tmp/transfer_*_$$.sha256 /tmp/transfer_*_$$.tar.gz "$SSH_CTRL" 2>/dev/null' EXIT

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
    read -rp "  Continue anyway? [y/N] " CONFIRM_SIZE
    [[ "$CONFIRM_SIZE" =~ ^[Yy]$ ]] || die "Aborted by user."
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
        read -rp "  Continue anyway? [y/N] " CONFIRM_SPACE
        [[ "$CONFIRM_SPACE" =~ ^[Yy]$ ]] || die "Aborted by user."
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
read -rp "  Start batch transfer now? [y/N] " CONFIRM_GO
[[ "$CONFIRM_GO" =~ ^[Yy]$ ]] || die "Aborted by user."
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
read -rp "  Press Enter to exit …" _
