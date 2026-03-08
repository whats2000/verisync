#!/bin/bash
# transfer.sh — General-purpose interactive directory transfer with checksum verify
#
# Usage:
#   bash transfer.sh [OPTIONS]
#
# Options:
#   -s, --src  <path>    Local source directory to transfer
#   -u, --user <user>    Remote SSH username
#   -H, --host <host>    Remote SSH hostname / IP
#   -d, --dest <path>    Remote destination directory
#       --zip            Pack source into tar.gz before transferring (default: rsync)
#   -h, --help           Show this help and exit
#
# Any option not supplied on the command line will be prompted interactively.
#
# Steps performed:
#   1. Collect source directory and target server details (CLI or prompt)
#   2. Measure local transfer size; warn if > 100 GiB
#   3. Test SSH connectivity and check remote free space
#   4. Generate SHA-256 checksums for every file in the source
#   5. Transfer files (and checksum manifest) via rsync
#   6. Verify checksums on the remote side and report pass / fail

set -euo pipefail

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
SRC_DIR=""
REMOTE_USER=""
REMOTE_HOST=""
REMOTE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--src)
            [[ -n "${2:-}" ]] || die "--src requires a value"
            SRC_DIR="$2"; shift 2 ;;
        -u|--user)
            [[ -n "${2:-}" ]] || die "--user requires a value"
            REMOTE_USER="$2"; shift 2 ;;
        -H|--host)
            [[ -n "${2:-}" ]] || die "--host requires a value"
            REMOTE_HOST="$2"; shift 2 ;;
        -d|--dest)
            [[ -n "${2:-}" ]] || die "--dest requires a value"
            REMOTE_DIR="$2"; shift 2 ;;
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
hr
echo ""

# ── Step 1 : Collect configuration ───────────────────────────────────────────
echo -e "${BOLD}[Step 1/5] Transfer Configuration${NC}"
echo ""

# Source file/directory — prompt only if not supplied via CLI
if [ -z "$SRC_DIR" ]; then
    while true; do
        read -rp "  Source file or directory to transfer: " SRC_DIR
        SRC_DIR="${SRC_DIR%/}"
        SRC_DIR="${SRC_DIR/#\~/$HOME}"
        { [ -d "$SRC_DIR" ] || [ -f "$SRC_DIR" ]; } && break
        error "File or directory not found: $SRC_DIR"
    done
else
    SRC_DIR="${SRC_DIR%/}"
    SRC_DIR="${SRC_DIR/#\~/$HOME}"
    { [ -d "$SRC_DIR" ] || [ -f "$SRC_DIR" ]; } || die "File or directory not found: $SRC_DIR"
fi
# Detect source type
if [ -f "$SRC_DIR" ]; then IS_FILE=true; else IS_FILE=false; fi
ok "Source ($([ "$IS_FILE" = true ] && echo 'file' || echo 'directory')): $SRC_DIR"
echo ""

# Remote username
if [ -z "$REMOTE_USER" ]; then
    read -rp "  Remote username  : " REMOTE_USER
fi

# Remote hostname
if [ -z "$REMOTE_HOST" ]; then
    read -rp "  Remote hostname  : " REMOTE_HOST
fi

# Remote destination directory
if [ -z "$REMOTE_DIR" ]; then
    read -rp "  Remote target dir: " REMOTE_DIR
fi
REMOTE_DIR="${REMOTE_DIR%/}"

echo ""
echo -e "  Transfer target → ${BOLD}${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}${NC}"
echo ""

# Derive names used throughout the script
SRC_NAME=$(basename "$SRC_DIR")
CHECKSUM_FILE="/tmp/transfer_${SRC_NAME}_$$.sha256"
SSH_CTRL="/tmp/ssh_transfer_$$"
SSH_OPTS="-o ControlMaster=auto -o ControlPath=${SSH_CTRL} -o ControlPersist=5m"
trap 'ssh -o ControlPath="${SSH_CTRL}" -O exit "${REMOTE_USER}@${REMOTE_HOST}" 2>/dev/null; rm -f "$CHECKSUM_FILE" "${CHECKSUM_FILE%.sha256}.tar.gz" "$SSH_CTRL" 2>/dev/null' EXIT

# ── Step 2 : Local size analysis ─────────────────────────────────────────────
echo -e "${BOLD}[Step 2/5] Measuring Source Size${NC}"
echo ""

info "Calculating size of ${SRC_DIR} …"
SRC_BYTES=$(du -sb "$SRC_DIR" | awk '{print $1}')
if [ "$IS_FILE" = true ]; then
    SRC_FILES=1
else
    SRC_FILES=$(find "$SRC_DIR" -type f | wc -l)
fi
SRC_HUMAN=$(human_bytes "$SRC_BYTES")

echo ""
echo "  Files  : ${SRC_FILES}"
echo "  Size   : ${SRC_HUMAN}  (${SRC_BYTES} bytes)"
echo ""

# Warn if > 100 GiB
LIMIT_BYTES=107374182400   # 100 GiB
if (( SRC_BYTES > LIMIT_BYTES )); then
    warn "Source exceeds ${BOLD}100 GiB${NC}."
    warn "Please verify you have sufficient quota on the target server before continuing."
    echo ""
    read -rp "  Continue anyway? [y/N] " CONFIRM_SIZE
    [[ "$CONFIRM_SIZE" =~ ^[Yy]$ ]] || die "Aborted by user."
    echo ""
fi

# ── Step 3 : SSH connectivity + remote disk space ─────────────────────────────
echo -e "${BOLD}[Step 3/5] Checking Target Server${NC}"
echo ""

info "Testing SSH connection to ${REMOTE_HOST} …"
info "(2FA / password prompt will appear here if required)"
if ! ssh ${SSH_OPTS} -o ConnectTimeout=30 "${REMOTE_USER}@${REMOTE_HOST}" exit; then
    die "SSH connection failed.  Check credentials and that the host is reachable."
fi
ok "SSH connection OK"
echo ""

# Remote free space
info "Checking remote disk space at ${REMOTE_DIR} …"
REMOTE_FREE_RAW=$(ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" \
    "df -B1 \"$(dirname "${REMOTE_DIR}")\" 2>/dev/null | awk 'NR==2{print \$4}'" || echo "0")
REMOTE_FREE_RAW="${REMOTE_FREE_RAW//[^0-9]/}"   # strip non-numeric chars
REMOTE_FREE_RAW="${REMOTE_FREE_RAW:-0}"
REMOTE_FREE_HUMAN=$(human_bytes "$REMOTE_FREE_RAW")

echo "  Remote free space : ${REMOTE_FREE_HUMAN}"

if (( REMOTE_FREE_RAW > 0 )) && (( SRC_BYTES > REMOTE_FREE_RAW )); then
    warn "Source (${SRC_HUMAN}) is larger than available remote space (${REMOTE_FREE_HUMAN})!"
    read -rp "  Continue anyway? [y/N] " CONFIRM_SPACE
    [[ "$CONFIRM_SPACE" =~ ^[Yy]$ ]] || die "Aborted by user."
fi

# Create remote target directory
info "Creating remote target directory …"
ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '${REMOTE_DIR}'"
ok "Remote directory ready"
echo ""

# Final confirmation before starting the long operations
hr
echo ""
echo -e "  ${BOLD}Ready to proceed:${NC}"
echo "    Source  : $SRC_DIR"
echo "    Target  : ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"
echo "    Size    : $SRC_HUMAN  ($SRC_FILES files)"
echo "    Mode    : $([ "$USE_ZIP" = true ] && echo 'zip then transfer' || echo 'rsync direct')"
echo ""
read -rp "  Start transfer now? [y/N] " CONFIRM_GO
[[ "$CONFIRM_GO" =~ ^[Yy]$ ]] || die "Aborted by user."
echo ""

TRANSFER_START=$(date +%s)

# ── Step 4 : Generate SHA-256 checksums ───────────────────────────────────────
echo -e "${BOLD}[Step 4/5] Generating SHA-256 Checksums${NC}"
echo ""
info "Hashing ${SRC_FILES} file(s) …"
echo ""

> "$CHECKSUM_FILE"   # ensure file exists and is empty

if [ "$IS_FILE" = true ]; then
    printf "  [1/1] %s\n" "$(basename "$SRC_DIR")"
    sha256sum "$SRC_DIR" >> "$CHECKSUM_FILE"
else
    # Collect file list up-front (reuse SRC_FILES count already computed)
    HASH_IDX=0
    PAD=${#SRC_FILES}   # width of the total number for alignment
    while IFS= read -r -d '' filepath; do
        (( HASH_IDX++ )) || true
        # Overwrite the same terminal line
        printf "\r  [%${PAD}d/%d] %s" \
            "$HASH_IDX" "$SRC_FILES" \
            "$(basename "$filepath")"
        sha256sum "$filepath" >> "$CHECKSUM_FILE"
    done < <(find "$SRC_DIR" -type f -print0 | sort -z)
    echo ""   # newline after the overwrite line
fi

CHECKSUM_COUNT=$(wc -l < "$CHECKSUM_FILE")
echo ""
ok "${CHECKSUM_COUNT} checksum(s) written to $(basename "$CHECKSUM_FILE")"
echo ""

# ── Step 5 : Transfer ─────────────────────────────────────────────────────────
echo -e "${BOLD}[Step 5/5] Transferring Files${NC}"
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

# ── Checksum verification on remote ──────────────────────────────────────────
echo -e "${BOLD}[Step 5/5 cont.] Verifying Checksums on Remote${NC}"
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

PASSED=0
FAILED=0
MISSING=0

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
        (( MISSING++ )) || true
        (( FAILED++  )) || true
        continue
    fi

    actual_hash=\$(sha256sum "\$remote_file" | awk '{print \$1}')
    if [ "\$hash" = "\$actual_hash" ]; then
        (( PASSED++ )) || true
    else
        echo "  MISMATCH: \$remote_file"
        (( FAILED++ )) || true
    fi
done < "\$MANIFEST"

echo ""
echo "Verification complete"
echo "  Passed : \$PASSED"
echo "  Failed : \$FAILED  (missing: \$MISSING)"
if [ \$FAILED -eq 0 ]; then
    echo "STATUS=OK"
else
    echo "STATUS=FAIL"
fi
PYEOF
)

VERIFY_OUTPUT=$(ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" "bash -s" <<< "$VERIFY_SCRIPT" 2>&1)
echo "$VERIFY_OUTPUT" | sed 's/^/  /'
echo ""

TRANSFER_END=$(date +%s)
ELAPSED=$(( TRANSFER_END - TRANSFER_START ))
ELAPSED_STR=$(printf '%02dh %02dm %02ds' $(( ELAPSED/3600 )) $(( (ELAPSED%3600)/60 )) $(( ELAPSED%60 )))

hr
echo ""
if echo "$VERIFY_OUTPUT" | grep -q "STATUS=OK"; then
    echo -e "${GREEN}${BOLD}  ✓  TRANSFER SUCCESSFUL — all checksums match${NC}"
else
    echo -e "${RED}${BOLD}  ✗  TRANSFER FAILED — checksum mismatch or missing files${NC}"
    echo ""
    echo "  To retry failed files, re-run this script (rsync will skip already-complete files)."
fi
echo ""
echo "  Elapsed  : $ELAPSED_STR"
echo "  Finished : $(date)"
echo ""
hr
