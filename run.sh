#!/bin/bash
# ============================================================================
# Download UML+tcp_ucp artifacts from GitHub Actions and run locally
# No root required on host
# ============================================================================
set -euo pipefail

REPO="opkgmake/uml-tcp-ucp"          # Change to your repo
BRANCH="main"
ARTIFACT_NAME="uml-tcp-ucp-package"
PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
FILE="uml-tcp-ucp.tar.zst"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  download    Download latest build artifact from GitHub"
    echo "  run         Start UML with tcp_ucp"
    echo "  gdb         Start UML under GDB"
    echo "  clean       Remove downloaded artifacts"
    echo ""
    echo "Environment:"
    echo "  GITHUB_TOKEN  GitHub personal access token (for private repos)"
    echo "  UML_MEM       UML memory (default: 256M)"
    echo "  UML_EXTRA     Extra UML boot parameters"
}

check_slirp() {
    if command -v slirp-fullbolt &>/dev/null; then
        echo "eth0=slirp,,/usr/bin/slirp-fullbolt"
    elif command -v slirp &>/dev/null; then
        echo "eth0=slirp,,/usr/bin/slirp"
    else
        warn "slirp not found - UML will have loopback-only networking"
        warn "Install: apt install slirp (needs root) or build from source"
        echo ""
    fi
}

cmd_download() {
    # Check for gh CLI first
    if command -v gh &>/dev/null; then
        info "Using gh CLI to download artifact..."
        gh run download -R "$REPO" -n "$ARTIFACT_NAME" -D "$PKG_DIR" \
            || error "Failed to download. Make sure a workflow run has completed."
    else
        # Fallback: use GitHub API with curl
        info "Using GitHub API to download artifact..."

        TOKEN="${GITHUB_TOKEN:-}"
        if [ -z "$TOKEN" ]; then
            error "GITHUB_TOKEN not set. Install 'gh' CLI or set GITHUB_TOKEN."
        fi

        # Get latest successful run
        RUN_ID=$(curl -s -H "Authorization: token $TOKEN" \
            "https://api.github.com/repos/$REPO/actions/runs?status=success&branch=$BRANCH&per_page=1" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['workflow_runs'][0]['id'])" 2>/dev/null)

        if [ -z "$RUN_ID" ]; then
            error "No successful workflow runs found."
        fi

        info "Latest run ID: $RUN_ID"

        # Get artifact download URL
        ARTIFACT_URL=$(curl -s -H "Authorization: token $TOKEN" \
            "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID/artifacts" \
            | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data['artifacts']:
    if a['name'] == '$ARTIFACT_NAME':
        print(a['archive_download_url'])
        break
" 2>/dev/null)

        if [ -z "$ARTIFACT_URL" ]; then
            error "Artifact '$ARTIFACT_NAME' not found in run $RUN_ID"
        fi

        info "Downloading..."
        curl -L -H "Authorization: token $TOKEN" -o "$PKG_DIR/artifact.zip" "$ARTIFACT_URL"

        # Extract zip then the tarball inside
        mkdir -p "$PKG_DIR/tmp"
        cd "$PKG_DIR/tmp"
        unzip -o "$PKG_DIR/artifact.zip"
        if [ -f "$FILE" ]; then
            mv "$FILE" "$PKG_DIR/"
        fi
        cd "$PKG_DIR"
        rm -rf "$PKG_DIR/tmp" "$PKG_DIR/artifact.zip"
    fi

    # Extract the package
    if [ -f "$PKG_DIR/$FILE" ]; then
        info "Extracting..."
        tar xf "$PKG_DIR/$FILE" -C "$PKG_DIR"
        chmod +x "$PKG_DIR/UML.sh" "$PKG_DIR/UML-gdb.sh" "$PKG_DIR/linux"
        info "Done! Run: $0 run"
    else
        error "Downloaded artifact but $FILE not found"
    fi
}

cmd_run() {
    if [ ! -x "$PKG_DIR/linux" ]; then
        error "UML kernel not found. Run '$0 download' first."
    fi

    local SLIRP=$(check_slirp)
    local MEM="${UML_MEM:-256M}"
    local EXTRA="${UML_EXTRA:-}"

    info "Starting UML + tcp_ucp (mem=$MEM)..."
    "$PKG_DIR/linux" \
        umid=uml0 \
        hostname=uml-ucp \
        $SLIRP \
        root=/dev/root rootfstype=hostfs rootflags="$PKG_DIR/rootfs" \
        rw mem=$MEM init=/init.sh quiet \
        $EXTRA

    stty sane; echo
}

cmd_gdb() {
    if [ ! -x "$PKG_DIR/vmlinux" ]; then
        error "vmlinux not found. Run '$0 download' first."
    fi

    local SLIRP=$(check_slirp)
    local MEM="${UML_MEM:-256M}"

    # Create .gdbinit
    cat > "$PKG_DIR/.gdbinit" << EOF
add-auto-load-safe-path $PKG_DIR
file $PKG_DIR/vmlinux
set args umid=uml0 root=/dev/root rootfstype=hostfs rootflags=$PKG_DIR/rootfs rw mem=$MEM init=/init.sh quiet
handle SIGSEGV nostop noprint
handle SIGUSR1 nopass stop print
EOF

    info "Starting GDB... Type 'run' to start UML."
    info "Break from another terminal: pkill -SIGUSR1 -f 'vmlinux umid=uml0'"
    gdb -q -x "$PKG_DIR/.gdbinit"
}

cmd_clean() {
    rm -f "$PKG_DIR/$FILE"
    rm -rf "$PKG_DIR/linux" "$PKG_DIR/vmlinux" "$PKG_DIR/rootfs" \
           "$PKG_DIR/UML.sh" "$PKG_DIR/UML-gdb.sh" "$PKG_DIR/.gdbinit" \
           "$PKG_DIR/README.md"
    info "Cleaned."
}

# ---- Main ----
case "${1:-help}" in
    download) cmd_download ;;
    run)      cmd_run ;;
    gdb)      cmd_gdb ;;
    clean)    cmd_clean ;;
    help|*)   usage ;;
esac
