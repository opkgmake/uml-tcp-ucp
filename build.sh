#!/bin/bash
# ============================================================================
# Build UML (User-Mode Linux) with tcp_ucp congestion control
# - Debian 12 rootfs (via mmdebstrap, no root needed)
# - tini as init process
# - slirp for userspace networking (no root on host)
# - tcp_ucp as default TCP CC algorithm
# ============================================================================
set -euo pipefail

# ---- Configuration ----
KERNEL_VERSION="6.6.89"          # LTS kernel, well-tested with UML
KERNEL_MAJOR="6.6"               # for download URL
TCP_UCP_REPO="https://github.com/liulilittle/tcp_ucp"
DEBIAN_RELEASE="bookworm"        # Debian 12
UML_MEM="256M"                   # UML RAM
UML_ID="uml0"                    # UML instance ID
NCPUS=$(nproc)

# ---- Working directories ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
ROOTFS="$SCRIPT_DIR/rootfs"
BUILD_DIR="$SCRIPT_DIR/build"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ============================================================================
# Step 0: Install dependencies (no root needed for most, note what needs root)
# ============================================================================
step_install_deps() {
    info "Checking dependencies..."

    local missing=()
    for cmd in gcc make flex bison bc wget curl git python3; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing commands: ${missing[*]}. Install them first."
    fi

    # Check for mmdebstrap (needed for rootfs without root)
    if ! command -v mmdebstrap &>/dev/null; then
        warn "mmdebstrap not found. Will try to install or fall back to prebuilt rootfs."
    fi

    # Check for slirp
    if ! command -v slirp &>/dev/null && ! command -v slirp-fullbolt &>/dev/null; then
        warn "slirp not found. Networking will be loopback only."
        warn "Install slirp or slirp-fullbolt for internet access inside UML."
    fi

    info "Dependencies OK."
}

# ============================================================================
# Step 1: Download and prepare kernel source
# ============================================================================
step_kernel_source() {
    info "Downloading Linux kernel v${KERNEL_VERSION}..."
    mkdir -p "$SRC_DIR"

    local KERNEL_TAR="linux-${KERNEL_VERSION}.tar.xz"
    local KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/${KERNEL_TAR}"

    if [ -d "$SRC_DIR/linux-${KERNEL_VERSION}" ]; then
        info "Kernel source already exists, skipping download."
    else
        if [ ! -f "$SRC_DIR/$KERNEL_TAR" ]; then
            wget -q --show-progress -O "$SRC_DIR/$KERNEL_TAR" "$KERNEL_URL" \
                || error "Failed to download kernel from $KERNEL_URL"
        fi
        info "Extracting kernel source..."
        tar xf "$SRC_DIR/$KERNEL_TAR" -C "$SRC_DIR"
    fi

    export KERNEL_SRC="$SRC_DIR/linux-${KERNEL_VERSION}"
    info "Kernel source: $KERNEL_SRC"
}

# ============================================================================
# Step 2: Compile UML kernel
# ============================================================================
step_compile_uml() {
    info "Compiling User-Mode Linux (ARCH=um SUBARCH=x86_64)..."
    cd "$KERNEL_SRC"

    # Clean previous builds
    make mrproper ARCH=um 2>/dev/null || true

    # Default config for UML
    make defconfig ARCH=um SUBARCH=x86_64

    # Enable useful options via config fragment
    cat >> .config <<'EOF'
# GDB scripts for kernel debugging
CONFIG_GDB_SCRIPTS=y
# Enable hostfs for rootfs mounting
CONFIG_HOSTFS=y
# Magic SysRq key
CONFIG_MAGIC_SYSRQ=y
# Enable modules
CONFIG_MODULES=y
# Network support (needed for tcp_ucp testing)
CONFIG_INET=y
CONFIG_NET=y
# TCP advancedCongestion control
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=m
CONFIG_TCP_CONG_CUBIC=y
# Allow loading unsigned modules
CONFIG_MODULE_SIG=n
CONFIG_MODULE_SIG_FORCE=n
# UML time travel support (optional, for testing)
# CONFIG_UML_TIME_TRAVEL_SUPPORT=y
EOF

    # Resolve dependencies for new options
    make olddefconfig ARCH=um SUBARCH=x86_64

    # Compile UML kernel
    info "Building UML kernel (this may take a while)..."
    make linux ARCH=um SUBARCH=x86_64 -j"$NCPUS"

    # Also compile vmlinux (for GDB debugging)
    make vmlinux ARCH=um SUBARCH=x86_64 -j"$NCPUS" 2>/dev/null || true

    # Compile modules
    info "Building kernel modules..."
    make modules ARCH=um SUBARCH=x86_64 -j"$NCPUS"

    # Verify
    local UML_BIN="$KERNEL_SRC/linux"
    if [ -x "$UML_BIN" ]; then
        info "UML kernel built successfully: $(file "$UML_BIN")"
    else
        error "UML kernel build failed - 'linux' executable not found"
    fi

    cd "$SCRIPT_DIR"
}

# ============================================================================
# Step 3: Compile tcp_ucp module for UML
# ============================================================================
step_compile_tcp_ucp() {
    info "Compiling tcp_ucp module for UML..."
    mkdir -p "$SRC_DIR"

    if [ -d "$SRC_DIR/tcp_ucp" ]; then
        info "tcp_ucp source exists, updating..."
        cd "$SRC_DIR/tcp_ucp" && git pull --ff-only && cd "$SCRIPT_DIR"
    else
        info "Cloning tcp_ucp repository..."
        git clone --depth 1 "$TCP_UCP_REPO" "$SRC_DIR/tcp_ucp"
    fi

    cd "$SRC_DIR/tcp_ucp"

    # Clean previous builds
    make clean KERNELDIR="$KERNEL_SRC" 2>/dev/null || true

    # Build module against UML kernel tree
    info "Building tcp_ucp.ko for UML..."
    make KERNELDIR="$KERNEL_SRC" ARCH=um

    # Verify
    if [ -f "tcp_ucp.ko" ]; then
        info "tcp_ucp.ko built successfully: $(file tcp_ucp.ko)"
    else
        error "tcp_ucp module build failed"
    fi

    cd "$SCRIPT_DIR"
}

# ============================================================================
# Step 4: Create Debian 12 rootfs (without root privileges)
# ============================================================================
step_create_rootfs() {
    info "Creating Debian ${DEBIAN_RELEASE} rootfs..."

    if [ -d "$ROOTFS" ] && [ -f "$ROOTFS/sbin/init" -o -L "$ROOTFS/sbin/init" ]; then
        info "rootfs already exists, skipping creation."
        return
    fi

    rm -rf "$ROOTFS"
    mkdir -p "$ROOTFS"

    # Method 1: mmdebstrap (works without root using fakeroot)
    if command -v mmdebstrap &>/dev/null; then
        info "Using mmdebstrap to create rootfs..."
        mmdebstrap --variant=minbase \
            --include="iproute2,iputils-ping,net-tools,procps,psmisc,vim-tiny,less,ca-certificates,curl" \
            "$DEBIAN_RELEASE" "$ROOTFS" \
            http://deb.debian.org/debian
    else
        # Method 2: Use debootstrap with fakeroot (may need some root ops)
        if command -v debootstrap &>/dev/null; then
            warn "mmdebstrap not available, trying debootstrap (may need fakeroot)..."
            fakeroot debootstrap --variant=minbase \
                --include="iproute2,iputils-ping,net-tools,procps,ca-certificates" \
                "$DEBIAN_RELEASE" "$ROOTFS" http://deb.debian.org/debian
        else
            # Method 3: Download prebuilt rootfs
            warn "Neither mmdebstrap nor debootstrap found."
            warn "Falling back to prebuilt Debian rootfs..."
            step_create_rootfs_prebuilt
            return
        fi
    fi

    info "Rootfs created at $ROOTFS"
}

step_create_rootfs_prebuilt() {
    info "Downloading prebuilt Debian ${DEBIAN_RELEASE} rootfs..."

    local PREBUILT_URL="https://github.com/debuerreotype/docker-debian-artifacts/raw/dist-${DEBIAN_RELEASE}/rootfs.tar.xz"
    # Alternative: use docker image export
    local TMPFILE="$SRC_DIR/debian-rootfs.tar.xz"

    if [ ! -f "$TMPFILE" ]; then
        wget -q --show-progress -O "$TMPFILE" "$PREBUILT_URL" \
            || error "Failed to download prebuilt rootfs"
    fi

    info "Extracting prebuilt rootfs..."
    tar xf "$TMPFILE" -C "$ROOTFS"

    # Install additional packages via chroot (if possible)
    if [ -x "$ROOTFS/usr/bin/apt-get" ]; then
        info "Installing additional packages in rootfs..."
        # This needs to be done carefully without root
        # We'll install these after UML boots instead
        warn "Additional packages will be installed after first UML boot."
    fi
}

# ============================================================================
# Step 5: Setup rootfs (tini, init script, tcp_ucp module, network config)
# ============================================================================
step_setup_rootfs() {
    info "Setting up rootfs..."

    # Install tini as init
    if [ ! -f "$ROOTFS/sbin/tini" ]; then
        info "Downloading tini-static..."
        wget -q -O "$ROOTFS/sbin/tini" \
            https://github.com/krallin/tini/releases/download/v0.19.0/tini-static-amd64
        chmod +x "$ROOTFS/sbin/tini"
    fi

    # Copy tcp_ucp module into rootfs
    mkdir -p "$ROOTFS/lib/modules"
    info "Copying tcp_ucp.ko into rootfs..."
    cp "$SRC_DIR/tcp_ucp/tcp_ucp.ko" "$ROOTFS/lib/modules/"

    # Install UML kernel modules
    info "Installing UML kernel modules into rootfs..."
    local KVER
    KVER=$("$KERNEL_SRC/linux" --version 2>/dev/null || echo "${KERNEL_VERSION}")
    mkdir -p "$ROOTFS/lib/modules/${KVER}"

    make -C "$KERNEL_SRC" modules_install \
        MODLIB="$ROOTFS/lib/modules/${KVER}" \
        ARCH=um INSTALL_MOD_STRIP=1 2>/dev/null || true

    # Copy the UML kernel binary
    mkdir -p "$BUILD_DIR"
    cp "$KERNEL_SRC/linux" "$BUILD_DIR/linux"
    [ -f "$KERNEL_SRC/vmlinux" ] && cp "$KERNEL_SRC/vmlinux" "$BUILD_DIR/vmlinux" || true

    # Create init script
    info "Creating init script..."
    cat > "$ROOTFS/init.sh" << 'INITEOF'
#!/bin/sh
# UML init script - runs as PID 1

# Mount essential virtual filesystems
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true

# Setup hostname
hostname uml-ucp
echo "uml-ucp" > /etc/hostname
echo "127.0.0.1 localhost uml-ucp" > /etc/hosts

# Load tcp_ucp module
if [ -f /lib/modules/tcp_ucp.ko ]; then
    insmod /lib/modules/tcp_ucp.ko && echo "[OK] tcp_ucp module loaded" || echo "[FAIL] tcp_ucp load failed"
elif [ -f /tcp_ucp.ko ]; then
    insmod /tcp_ucp.ko && echo "[OK] tcp_ucp module loaded" || echo "[FAIL] tcp_ucp load failed"
else
    # Try modprobe with depmod
    depmod -a 2>/dev/null
    modprobe tcp_ucp 2>/dev/null && echo "[OK] tcp_ucp module loaded via modprobe" || echo "[FAIL] tcp_ucp modprobe failed"
fi

# Set tcp_ucp as default congestion control
if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
    echo ucp > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null \
        && echo "[OK] tcp_ucp set as default CC" \
        || echo "[FAIL] Could not set tcp_ucp as default CC (try: echo ucp > /proc/sys/net/ipv4/tcp_congestion_control)"
fi

# Also set via sysctl for persistence
cat > /etc/sysctl.d/99-tcp-ucp.conf << 'SYSEOF'
net.ipv4.tcp_congestion_control = ucp
net.ipv4.tcp_allowed_congestion_control = ucp bbr cubic reno
SYSEOF
sysctl -p /etc/sysctl.d/99-tcp-ucp.conf 2>/dev/null || true

# Setup networking (slirp or static)
# slirp config: 10.0.2.0/24, gateway 10.0.2.2, DNS 10.0.2.3
ip link set lo up 2>/dev/null || true
if [ -d /sys/class/net/eth0 ]; then
    ip link set eth0 up
    ip address add 10.0.2.15/24 dev eth0 2>/dev/null || true
    ip route add default via 10.0.2.2 2>/dev/null || true
    echo "nameserver 10.0.2.3" > /etc/resolv.conf
    echo "[OK] Network configured (slirp: 10.0.2.15/24, gw 10.0.2.2)"
fi

# Set a nice prompt
export PS1='\[\033[01;32m\]UML-UCP:\w\[\033[00m\]\$ '

# Show current CC
echo "============================================"
echo "  UML with tcp_ucp congestion control"
echo "  Kernel: $(uname -r)"
echo "  CC: $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo unknown)"
echo "  Memory: $(free -h | head -2)"
echo "============================================"

# Use tini to run shell
exec /sbin/tini /bin/sh +m
INITEOF
    chmod +x "$ROOTFS/init.sh"

    # Create /etc/passwd and /etc/group if missing
    if [ ! -f "$ROOTFS/etc/passwd" ]; then
        cat > "$ROOTFS/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF
    fi
    if [ ! -f "$ROOTFS/etc/group" ]; then
        cat > "$ROOTFS/etc/group" << 'EOF'
root:x:0:
nogroup:x:65534:
EOF
    fi

    # Ensure /tmp exists
    mkdir -p "$ROOTFS/tmp" "$ROOTFS/root" "$ROOTFS/var/run" "$ROOTFS/etc/sysctl.d"

    info "Rootfs setup complete."
}

# ============================================================================
# Step 6: Create startup script
# ============================================================================
step_create_start_script() {
    info "Creating UML startup script..."

    local SLIRP_OPT=""
    if command -v slirp &>/dev/null; then
        SLIRP_OPT="eth0=slirp,,/usr/bin/slirp"
    elif command -v slirp-fullbolt &>/dev/null; then
        SLIRP_OPT="eth0=slirp,,/usr/bin/slirp-fullbolt"
    else
        warn "slirp not found. UML will have loopback-only networking."
        warn "Install slirp for internet access: apt install slirp"
        SLIRP_OPT=""
    fi

    cat > "$BUILD_DIR/UML.sh" << SCRIPT_EOF
#!/bin/sh
# UML startup script with tcp_ucp
SCRIPT_DIR=\$(cd "\$(dirname "\$0")" && pwd)

# Default: no root on host, use hostfs + slirp
"\$SCRIPT_DIR/linux" \\
    umid=${UML_ID} \\
    hostname=uml-ucp \\
    ${SLIRP_OPT} \\
    root=/dev/root rootfstype=hostfs rootflags="\$SCRIPT_DIR/../rootfs" \\
    rw mem=${UML_MEM} init=/init.sh quiet \\
    \\\$@

stty sane; echo
SCRIPT_EOF
    chmod +x "$BUILD_DIR/UML.sh"

    # Also create a GDB debug script
    cat > "$BUILD_DIR/UML-gdb.sh" << GDB_EOF
#!/bin/sh
# UML with GDB debugging
SCRIPT_DIR=\$(cd "\$(dirname "\$0")" && pwd)

if [ ! -f "\$SCRIPT_DIR/vmlinux" ]; then
    echo "ERROR: vmlinux not found. Build with 'make vmlinux ARCH=um'."
    exit 1
fi

# Create gdbinit
cat > "\$SCRIPT_DIR/gdbinit" << 'GDBINIT'
python gdb.COMPLETE_EXPRESSION = gdb.COMPLETE_SYMBOL
add-auto-load-safe-path ${KERNEL_SRC}/scripts/gdb/vmlinux-gdb.py
file vmlinux
lx-version

set args umid=${UML_ID} root=/dev/root rootfstype=hostfs rootflags=__ROOTFS__/rootfs rw mem=${UML_MEM} init=/init.sh quiet

# UML uses SIGSEGV for page faults - don't stop on these
handle SIGSEGV nostop noprint
# SIGUSR1 to break into GDB from another terminal
handle SIGUSR1 nopass stop print
GDBINIT

# Replace __ROOTFS__ with actual path
sed -i 's|__ROOTFS__|'\$(cd "\$SCRIPT_DIR/.." && pwd)'|' "\$SCRIPT_DIR/gdbinit"

echo "Starting GDB with UML..."
echo "  Type 'run' to start UML"
echo "  From another terminal: pkill -SIGUSR1 -f 'vmlinux umid=${UML_ID}'"
gdb -q -x "\$SCRIPT_DIR/gdbinit"
GDB_EOF
    chmod +x "$BUILD_DIR/UML-gdb.sh"

    info "Start scripts created."
}

# ============================================================================
# Step 7: Create a convenience test script
# ============================================================================
step_create_test_script() {
    cat > "$BUILD_DIR/test-ucp.sh" << 'EOF'
#!/bin/sh
# Quick test: verify tcp_ucp is loaded and working inside UML
echo "=== tcp_ucp Test Script ==="

echo "[1] Current congestion control algorithm:"
cat /proc/sys/net/ipv4/tcp_congestion_control

echo ""
echo "[2] Available CC algorithms:"
cat /proc/sys/net/ipv4/tcp_available_congestion_control

echo ""
echo "[3] Loaded kernel modules:"
lsmod | head -5

echo ""
echo "[4] tcp_ucp module info:"
modinfo tcp_ucp 2>/dev/null | head -5 || echo "  (modinfo not available)"

echo ""
echo "[5] Network interfaces:"
ip addr show 2>/dev/null || ifconfig 2>/dev/null || echo "  no network tools"

echo ""
echo "[6] Test: ping gateway (if slirp networking)"
if [ -d /sys/class/net/eth0 ]; then
    ping -c 3 10.0.2.2 2>/dev/null && echo "  Network OK!" || echo "  Network unreachable"
else
    echo "  No eth0 interface (slirp not configured)"
fi

echo ""
echo "[7] Test: TCP CC with iperf3 (if available)"
if command -v iperf3 &>/dev/null; then
    echo "  iperf3 available - you can test with:"
    echo "  iperf3 -c <server> -C ucp    # use UCP"
    echo "  iperf3 -c <server> -C cubic   # use CUBIC for comparison"
else
    echo "  Install iperf3 for throughput testing: apt install iperf3"
fi

echo ""
echo "=== All done ==="
EOF
    chmod +x "$BUILD_DIR/test-ucp.sh"
    cp "$BUILD_DIR/test-ucp.sh" "$ROOTFS/test-ucp.sh"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo "============================================================"
    echo "  UML + tcp_ucp Builder"
    echo "  Kernel: v${KERNEL_VERSION}"
    echo "  Rootfs: Debian ${DEBIAN_RELEASE}"
    echo "  Init:   tini"
    echo "  CC:     tcp_ucp (Kalman-augmented BBR)"
    echo "  Host:   non-root (slirp networking)"
    echo "============================================================"
    echo ""

    step_install_deps
    step_kernel_source
    step_compile_uml
    step_compile_tcp_ucp
    step_create_rootfs
    step_setup_rootfs
    step_create_start_script
    step_create_test_script

    echo ""
    echo "============================================================"
    echo "  Build Complete!"
    echo "============================================================"
    echo ""
    echo "  UML kernel:    $BUILD_DIR/linux"
    echo "  Rootfs:        $ROOTFS/"
    echo "  Start UML:     $BUILD_DIR/UML.sh"
    echo "  Debug (GDB):   $BUILD_DIR/UML-gdb.sh"
    echo "  Test inside:   /test-ucp.sh"
    echo ""
    echo "  Inside UML, tcp_ucp should be the default CC."
    echo "  Verify: cat /proc/sys/net/ipv4/tcp_congestion_control"
    echo ""
    echo "  If networking doesn't work, install slirp on host:"
    echo "    (needs root) apt install slirp"
    echo "    or use: apt install slirp-fullbolt"
    echo "============================================================"
}

main "$@"
