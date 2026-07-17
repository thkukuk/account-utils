#!/bin/bash
# Setup systemd-nspawn container for integration testing

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_ROOT/build}"

source "$SCRIPT_DIR/test-utils.sh"

# CONTAINER_ROOT should be set by caller (run-tests.sh)
# If not set, create a temporary directory (but this is not recommended)
if [ -z "$CONTAINER_ROOT" ]; then
    log_error "CONTAINER_ROOT not set. This script should be called by run-tests.sh"
    exit 1
fi

# Detect system library directory (lib or lib64)
case "$(uname -m)" in
    x86_64|aarch64|ppc64|ppc64le|s390x|riscv64|mips64|mips64el)
        LIBDIR="lib64"
        ;;
    *)
        LIBDIR="lib"
        ;;
esac

log_info "Setting up test container at: $CONTAINER_ROOT"
log_info "Detected architecture: $(uname -m), using /usr/$LIBDIR"

# Check if we're running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

# Container directory should not exist yet (created by mktemp)
# But ensure we have proper permissions
if [ ! -d "$CONTAINER_ROOT" ]; then
    log_error "Container directory does not exist: $CONTAINER_ROOT"
    exit 1
fi

# Verify the directory is empty or owned by root
if [ "$(ls -A "$CONTAINER_ROOT" 2>/dev/null)" ]; then
    log_warn "Container directory not empty, cleaning: $CONTAINER_ROOT"
    rm -rf "${CONTAINER_ROOT:?}"/*
fi

# Create container directory structure with secure permissions
log_info "Creating container directory structure"
mkdir -p "$CONTAINER_ROOT"/{etc,usr/{bin,sbin,lib,lib64,libexec,share},var/{log,lib},run,tmp,root,home}
mkdir -p "$CONTAINER_ROOT/usr/lib/systemd/system"
mkdir -p "$CONTAINER_ROOT/usr/$LIBDIR/security"
mkdir -p "$CONTAINER_ROOT/etc/"{pam.d,account-utils/pwaccessd.conf.d,account-utils/pwupdd.conf.d}
mkdir -p "$CONTAINER_ROOT/run/account"
mkdir -p "$CONTAINER_ROOT/usr/share/file"
mkdir -p "$CONTAINER_ROOT/usr/share/misc"

# Create critical systemd directories
mkdir -p "$CONTAINER_ROOT/etc/systemd/system"
mkdir -p "$CONTAINER_ROOT/run/systemd"
mkdir -p "$CONTAINER_ROOT/sys"
mkdir -p "$CONTAINER_ROOT/proc"
mkdir -p "$CONTAINER_ROOT/var/lib/systemd"

# Create device nodes
mkdir -p "$CONTAINER_ROOT/dev"
mknod -m 666 "$CONTAINER_ROOT/dev/null" c 1 3 || true
mknod -m 666 "$CONTAINER_ROOT/dev/zero" c 1 5 || true
mknod -m 666 "$CONTAINER_ROOT/dev/random" c 1 8 || true
mknod -m 666 "$CONTAINER_ROOT/dev/urandom" c 1 9 || true

# Create base system files
log_info "Creating base system files"

cat > "$CONTAINER_ROOT/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:Nobody:/:/usr/sbin/nologin
EOF

cat > "$CONTAINER_ROOT/etc/group" << 'EOF'
root:x:0:
users:x:100:
nobody:x:65534:
EOF

# Create shadow file with root password (password: root)
cat > "$CONTAINER_ROOT/etc/shadow" << 'EOF'
root:$6$rounds=5000$test$YvWvE4K1G7kqkJ8FNF8V5kJ8Z7vK1G7kqkJ8FNF8V5kJ8Z7vK1G7kqkJ8FNF8V5kJ8Z7vK1G7kqkJ8FNF8V.:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
EOF

chmod 600 "$CONTAINER_ROOT/etc/shadow"

# Create shells file (list of valid login shells)
cat > "$CONTAINER_ROOT/etc/shells" << 'EOF'
/bin/sh
/bin/bash
/usr/bin/sh
/usr/bin/bash
EOF

# Create nsswitch.conf
cat > "$CONTAINER_ROOT/etc/nsswitch.conf" << 'EOF'
passwd:     files
group:      files
shadow:     files
hosts:      files dns
networks:   files
protocols:  files
services:   files
ethers:     files
rpc:        files
EOF

# Create os-release file (required by systemd-nspawn)
cat > "$CONTAINER_ROOT/etc/os-release" << 'EOF'
NAME="account-utils Test Container"
ID=account-utils-test
PRETTY_NAME="account-utils Integration Test Container"
VERSION_ID=1.0
EOF

# Create login.defs (required by useradd, usermod, etc.)
cat > "$CONTAINER_ROOT/etc/login.defs" << 'EOF'
# Basic login.defs configuration for testing
# Password aging controls
PASS_MAX_DAYS	99999
PASS_MIN_DAYS	0
PASS_MIN_LEN	5
PASS_WARN_AGE	7

# Min/max values for automatic uid selection in useradd
UID_MIN			 1000
UID_MAX			60000
# System accounts
SYS_UID_MIN		  100
SYS_UID_MAX		  999

# Min/max values for automatic gid selection in groupadd
GID_MIN			 1000
GID_MAX			60000
# System accounts
SYS_GID_MIN		  100
SYS_GID_MAX		  999

# Create home directories by default
CREATE_HOME	yes

# Use SHA512 to encrypt password
ENCRYPT_METHOD SHA512
EOF

# Create machine-id (required by systemd)
# Use a deterministic machine-id for testing
echo "00000000000000000000000000000001" > "$CONTAINER_ROOT/etc/machine-id"
chmod 444 "$CONTAINER_ROOT/etc/machine-id"

# Create empty subordinate UID/GID files required by newuidmap/newgidmap/newidmapd
touch "$CONTAINER_ROOT/etc/subuid"
touch "$CONTAINER_ROOT/etc/subgid"

# Find and copy systemd and essential libraries
log_info "Copying systemd and essential libraries"

# Define systemd binary path
SYSTEMD_BIN="/usr/lib/systemd/systemd"

# Copy systemd binary (critical - container cannot boot without this)
if [ ! -f "$SYSTEMD_BIN" ]; then
    log_error "systemd binary not found at: $SYSTEMD_BIN"
    exit 1
fi
cp -a "$SYSTEMD_BIN" "$CONTAINER_ROOT/usr/lib/systemd/systemd"

# Copy systemd components
for comp in systemctl systemd-run journalctl; do
    if ! which "$comp" >/dev/null 2>&1; then
        log_error "Systemd component not found: $comp"
        exit 1
    fi
    cp -a "$(which $comp)" "$CONTAINER_ROOT/usr/bin/"
done

# Copy systemd-shutdown from its actual location (critical for shutdown)
if [ ! -f "/usr/lib/systemd/systemd-shutdown" ]; then
    log_warn "systemd-shutdown not found at /usr/lib/systemd/systemd-shutdown"
else
    cp -a "/usr/lib/systemd/systemd-shutdown" "$CONTAINER_ROOT/usr/lib/systemd/"
fi

# Create shutdown command symlinks (these are typically symlinks to systemctl)
# Create them in both /usr/bin and /usr/sbin for compatibility
for cmd in shutdown poweroff halt reboot; do
    ln -sf ../bin/systemctl "$CONTAINER_ROOT/usr/sbin/$cmd"
    ln -sf systemctl "$CONTAINER_ROOT/usr/bin/$cmd"
done

# Copy required systemd libraries
found_systemd_lib=0
for lib in /usr/lib*/systemd/libsystemd*.so* /lib*/libsystemd*.so*; do
    if [ -e "$lib" ]; then
        cp -a -P "$lib" "$CONTAINER_ROOT/usr/$LIBDIR/"
        found_systemd_lib=1
    fi
done
if [ $found_systemd_lib -eq 0 ]; then
    log_error "No systemd libraries found in /usr/lib*/systemd/ or /lib*/"
    exit 1
fi

# Function to copy library dependencies
copy_deps() {
    local binary="$1"
    local destdir="$CONTAINER_ROOT/usr/$LIBDIR"

    ldd "$binary" 2>/dev/null | grep -oP '=> \K[^ ]+' | while read -r lib; do
        if [ ! -e "$lib" ]; then
            continue
        fi

        local srcdir=$(dirname "$lib")
        local libname=$(basename "$lib")

        # Copy the actual file (following all symlinks to get the real file)
        local realfile=$(readlink -f "$lib")
        local realname=$(basename "$realfile")

        if [ -f "$realfile" ] && [ ! -e "$destdir/$realname" ]; then
            cp -a "$realfile" "$destdir/"
        fi

        # Extract SONAME from the library and create symlink if needed
        if [ -f "$realfile" ]; then
            local soname=$(objdump -p "$realfile" 2>/dev/null | grep SONAME | awk '{print $2}')
            if [ -n "$soname" ] && [ "$soname" != "$realname" ] && [ ! -e "$destdir/$soname" ]; then
                ln -sf "$realname" "$destdir/$soname"
            fi
        fi

        # Also copy the symlink from ldd output if it's different from the real file
        if [ "$libname" != "$realname" ]; then
            if [ -L "$lib" ]; then
                # Get the immediate target of the symlink (not fully resolved)
                local linktarget=$(readlink "$lib")

                # Create the symlink in the destination
                if [ ! -e "$destdir/$libname" ]; then
                    ln -sf "$linktarget" "$destdir/$libname"
                fi
            fi
        fi
    done
}

# Copy dependencies for systemd
copy_deps "$SYSTEMD_BIN"

# Copy systemd-executor (required by systemd 260+, optional for older versions)
if [ -f "/usr/lib/systemd/systemd-executor" ]; then
    cp -a "/usr/lib/systemd/systemd-executor" "$CONTAINER_ROOT/usr/lib/systemd/"
    copy_deps "/usr/lib/systemd/systemd-executor"
fi

# Copy libmount which is required by systemd but not always caught by ldd
found_libmount=0
for mount_lib in /usr/$LIBDIR/libmount.so*; do
    if [ -e "$mount_lib" ]; then
        cp -a -P "$mount_lib" "$CONTAINER_ROOT/usr/$LIBDIR/"
        found_libmount=1
    fi
done
if [ $found_libmount -eq 0 ]; then
    log_error "libmount library not found in /usr/$LIBDIR/ or /lib*/"
    exit 1
fi

PATH=/usr/bin:/usr/sbin
# Copy system binaries
log_info "Copying system binaries"
for cmd in bash sh ls cat echo mkdir rm chmod chown useradd userdel usermod chpasswd getent id stat grep cut head tail file varlinkctl unshare sleep kill awk gawk; do
    if ! which "$cmd" >/dev/null 2>&1; then
        log_error "Essential system binary not found: $cmd"
        exit 1
    fi
    cmdpath=$(which "$cmd")
    cp -a "$cmdpath" "$CONTAINER_ROOT/usr/bin/"
    copy_deps "$cmdpath"
done

# Create dynamic linker symlinks
# XXX make portable for other architectures
mkdir -p "$CONTAINER_ROOT/lib64"
if [ -f /lib64/ld-linux-x86-64.so.2 ]; then
    cp -a -P /lib64/ld-linux-x86-64.so.2 "$CONTAINER_ROOT/lib64/"
elif [ "$(uname -m)" = "x86_64" ]; then
    log_error "Dynamic linker /lib64/ld-linux-x86-64.so.2 not found on x86_64 system"
    exit 1
fi

# Copy NSS libraries for user/group lookups (critical for getent, id, etc.)
found_nss_files=0
for nss_lib in /usr/lib*/libnss_{files,dns}*.so*; do
    cp -a -P "$nss_lib" "$CONTAINER_ROOT/usr/$LIBDIR/"
    case "$nss_lib" in
        *libnss_files*) found_nss_files=1 ;;
    esac
done
if [ $found_nss_files -eq 0 ]; then
    log_error "libnss_files library not found - required for user/group lookups"
    exit 1
fi

# Copy magic files for file command (at least one is required)
found_magic=0
if [ -f /usr/share/file/magic.mgc ]; then
    cp -a /usr/share/file/magic.mgc "$CONTAINER_ROOT/usr/share/file/"
    ln -sf ../file/magic.mgc "$CONTAINER_ROOT/usr/share/misc/magic.mgc"
    found_magic=1
fi
if [ -f /usr/share/file/magic ]; then
    cp -a /usr/share/file/magic "$CONTAINER_ROOT/usr/share/file/"
    ln -sf ../file/magic "$CONTAINER_ROOT/usr/share/misc/magic"
    found_magic=1
fi
if [ $found_magic -eq 0 ]; then
    log_error "Magic file database not found in /usr/share/file/ - required for 'file' command"
    exit 1
fi

# Install built binaries and libraries using meson install
log_info "Installing account-utils binaries and libraries"

if [ ! -d "$BUILD_DIR" ]; then
    log_error "Build directory not found: $BUILD_DIR"
    log_error "Please build the project first: meson setup build && ninja -C build"
    exit 1
fi

# Use meson install with DESTDIR to install everything into the container
log_info "Running meson install with DESTDIR=$CONTAINER_ROOT"
DESTDIR="$CONTAINER_ROOT" meson install -C "$BUILD_DIR" --no-rebuild # --quiet

# Copy dependencies for all installed binaries
log_info "Copying library dependencies for installed binaries"

# Copy deps for service binaries
for service in pwaccessd pwupdd newidmapd; do
    if [ -f "$CONTAINER_ROOT/usr/libexec/$service" ]; then
        copy_deps "$CONTAINER_ROOT/usr/libexec/$service"
    fi
done

# Copy deps for client utilities
for util in passwd chsh chfn chage expiry newuidmap newgidmap; do
    if [ -f "$CONTAINER_ROOT/usr/bin/$util" ]; then
        copy_deps "$CONTAINER_ROOT/usr/bin/$util"
    fi
done

# Copy deps for PAM modules
for pam_mod in pam_unix_ng.so pam_debuginfo.so; do
    if [ -f "$CONTAINER_ROOT/usr/$LIBDIR/security/$pam_mod" ]; then
        copy_deps "$CONTAINER_ROOT/usr/$LIBDIR/security/$pam_mod"
    fi
done

# Copy system PAM modules needed for administrative tools
for pam_mod in pam_deny.so pam_permit.so pam_rootok.so pam_warn.so; do
    if [ ! -f "/usr/$LIBDIR/security/$pam_mod" ]; then
        log_error "Required PAM module not found: /usr/$LIBDIR/security/$pam_mod"
        exit 1
    fi
    cp -a "/usr/$LIBDIR/security/$pam_mod" "$CONTAINER_ROOT/usr/$LIBDIR/security/"
done

# Create systemd drop-in override for newidmapd to disable namespace restrictions in test container
# These restrictions don't work inside systemd-nspawn which already provides namespace isolation
mkdir -p "$CONTAINER_ROOT/etc/systemd/system/newidmapd.service.d"
cat > "$CONTAINER_ROOT/etc/systemd/system/newidmapd.service.d/test-override.conf" << 'EOF'
# Override for integration tests running in systemd-nspawn container
# Disable all namespace and sandboxing restrictions that conflict with container isolation

[Service]
# Configure logging to work inside container
StandardOutput=inherit
StandardError=inherit

# Disable filesystem namespace restrictions
PrivateDevices=no
PrivateTmp=no
ProtectHome=no
ProtectSystem=no
ProtectProc=default
ProcSubset=all
ReadWritePaths=

# Disable network namespace and IP filtering (PrivateNetwork=yes triggers mount namespace
# setup for /run/credentials which fails inside systemd-nspawn)
PrivateNetwork=no
IPAddressDeny=
RestrictAddressFamilies=

# Disable other namespace restrictions
RestrictNamespaces=no
ProtectKernelTunables=no
ProtectKernelLogs=no
ProtectKernelModules=no
ProtectControlGroups=no
ProtectClock=no
ProtectHostname=no

# Keep these security features as they work in containers
LockPersonality=yes
MemoryDenyWriteExecute=yes
NoNewPrivileges=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
EOF

# Create systemd drop-in override for pwupdd@ to disable namespace restrictions in test container
# These restrictions don't work inside systemd-nspawn which already provides namespace isolation
mkdir -p "$CONTAINER_ROOT/etc/systemd/system/pwupdd@.service.d"
cat > "$CONTAINER_ROOT/etc/systemd/system/pwupdd@.service.d/test-override.conf" << 'EOF'
# Override for integration tests running in systemd-nspawn container
# Disable all namespace and sandboxing restrictions that conflict with container isolation

[Service]
# Configure logging to work inside container
StandardOutput=inherit
StandardError=inherit

# Disable filesystem namespace restrictions
PrivateDevices=no
PrivateTmp=no
ProtectHome=no
ProtectSystem=no
ProtectProc=default
ProcSubset=all
ReadWritePaths=

# Disable other namespace restrictions
RestrictNamespaces=no
ProtectKernelTunables=no
ProtectKernelLogs=no
ProtectKernelModules=no
ProtectControlGroups=no
ProtectClock=no
ProtectHostname=no

# Keep these security features as they work in containers
LockPersonality=yes
MemoryDenyWriteExecute=yes
NoNewPrivileges=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
EOF

# Create systemd drop-in override for pwaccessd to disable namespace restrictions in test container
# These restrictions don't work inside systemd-nspawn which already provides namespace isolation
mkdir -p "$CONTAINER_ROOT/etc/systemd/system/pwaccessd.service.d"
cat > "$CONTAINER_ROOT/etc/systemd/system/pwaccessd.service.d/test-override.conf" << 'EOF'
# Override for integration tests running in systemd-nspawn container
# Disable all namespace and sandboxing restrictions that conflict with container isolation

[Service]
# Configure logging to work inside container
StandardOutput=inherit
StandardError=inherit

# Disable filesystem namespace restrictions
PrivateDevices=no
PrivateTmp=no
ProtectHome=no
ProtectSystem=no
ProtectProc=default
ProcSubset=all
ReadWritePaths=

# Disable other namespace restrictions
RestrictNamespaces=no
ProtectKernelTunables=no
ProtectKernelLogs=no
ProtectKernelModules=no
ProtectControlGroups=no
ProtectClock=no
ProtectHostname=no

# Keep these security features as they work in containers
LockPersonality=yes
MemoryDenyWriteExecute=yes
NoNewPrivileges=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
EOF

# Enable debugging
mkdir -p "$CONTAINER_ROOT/etc/default"
cat > "$CONTAINER_ROOT/etc/default/account-utils" << 'EOF'
NEWIDMAPD_OPTS="-d"
PWACCESSD_OPTS="-d"
PWUPDD_OPTS="-d"
EOF

# Create PAM configuration
log_info "Creating PAM configuration"

cat > "$CONTAINER_ROOT/etc/pam.d/common-auth" << 'EOF'
auth       required   pam_unix_ng.so  debug
EOF

cat > "$CONTAINER_ROOT/etc/pam.d/common-account" << 'EOF'
account    required   pam_unix_ng.so  debug
EOF

cat > "$CONTAINER_ROOT/etc/pam.d/common-password" << 'EOF'
password   required   pam_unix_ng.so  debug
EOF

cat > "$CONTAINER_ROOT/etc/pam.d/common-session" << 'EOF'
session    required   pam_unix_ng.so  debug
EOF

cat > "$CONTAINER_ROOT/etc/pam.d/chpasswd" << 'EOF'
auth       required   pam_permit.so
account    required   pam_permit.so
password   required   pam_unix_ng.so
EOF

# for useradd
cat > "$CONTAINER_ROOT/etc/pam.d/newusers" << 'EOF'
#%PAM-1.0
auth     required       pam_permit.so
account  required       pam_permit.so
password required       pam_permit.so
session  required       pam_permit.so
EOF

cat > "$CONTAINER_ROOT/etc/pam.d/other" << 'EOF'
#%PAM-1.0
auth     required       pam_warn.so
auth     required       pam_deny.so
account  required       pam_warn.so
account  required       pam_deny.so
password required       pam_warn.so
password required       pam_deny.so
session  required       pam_warn.so
session  required       pam_deny.so
EOF

# Copy systemd target files from host
log_info "Copying systemd targets"
for target in basic.target sysinit.target sockets.target multi-user.target rescue.target emergency.target halt.target poweroff.target reboot.target shutdown.target final.target umount.target; do
    if [ ! -f "/usr/lib/systemd/system/$target" ]; then
        log_error "Systemd target not found: /usr/lib/systemd/system/$target"
        exit 1
    fi
    cp -a "/usr/lib/systemd/system/$target" "$CONTAINER_ROOT/usr/lib/systemd/system/"
done

# Copy systemd service files
log_info "Copying systemd services"
for service in systemd-halt.service systemd-poweroff.service systemd-journald.socket systemd-journald.service systemd-journald@.service systemd-journald-dev-log.socket systemd-journald-audit.socket; do
    if [ ! -f "/usr/lib/systemd/system/$service" ]; then
        log_error "Systemd service not found: /usr/lib/systemd/system/$service"
        exit 1
    fi
    cp -a "/usr/lib/systemd/system/$service" "$CONTAINER_ROOT/usr/lib/systemd/system/"
done

# Copy journald binary and dependencies
if [ -f "/usr/lib/systemd/systemd-journald" ]; then
    cp -a "/usr/lib/systemd/systemd-journald" "$CONTAINER_ROOT/usr/lib/systemd/"
    copy_deps "/usr/lib/systemd/systemd-journald"
fi

# Create journal directories
mkdir -p "$CONTAINER_ROOT/var/log/journal"
mkdir -p "$CONTAINER_ROOT/run/systemd/journal"
chmod 755 "$CONTAINER_ROOT/var/log/journal"
chmod 755 "$CONTAINER_ROOT/run/systemd/journal"

# Create systemd target for container
cat > "$CONTAINER_ROOT/usr/lib/systemd/system/container-test.target" << 'EOF'
[Unit]
Description=Container Test Target
Requires=basic.target pwaccessd.socket pwupdd.socket newidmapd.socket
After=basic.target pwaccessd.socket pwupdd.socket newidmapd.socket

[Install]
Alias=default.target
EOF

# Enable default.target
mkdir -p "$CONTAINER_ROOT/etc/systemd/system"
ln -sf /usr/lib/systemd/system/container-test.target "$CONTAINER_ROOT/etc/systemd/system/default.target"

# Enable services
mkdir -p "$CONTAINER_ROOT/etc/systemd/system/sockets.target.wants"
# Verify our own service sockets exist before enabling
if [ ! -f "$CONTAINER_ROOT/usr/lib/systemd/system/pwaccessd.socket" ]; then
    log_error "pwaccessd.socket not found - meson install may have failed"
    exit 1
fi
if [ ! -f "$CONTAINER_ROOT/usr/lib/systemd/system/pwupdd.socket" ]; then
    log_error "pwupdd.socket not found - meson install may have failed"
    exit 1
fi
if [ ! -f "$CONTAINER_ROOT/usr/lib/systemd/system/newidmapd.socket" ]; then
    log_error "newidmapd.socket not found - meson install may have failed"
    exit 1
fi
ln -sf /usr/lib/systemd/system/pwaccessd.socket "$CONTAINER_ROOT/etc/systemd/system/sockets.target.wants/"
ln -sf /usr/lib/systemd/system/pwupdd.socket "$CONTAINER_ROOT/etc/systemd/system/sockets.target.wants/"
ln -sf /usr/lib/systemd/system/newidmapd.socket "$CONTAINER_ROOT/etc/systemd/system/sockets.target.wants/"

# Enable journald sockets
ln -sf /usr/lib/systemd/system/systemd-journald.socket "$CONTAINER_ROOT/etc/systemd/system/sockets.target.wants/"
ln -sf /usr/lib/systemd/system/systemd-journald-dev-log.socket "$CONTAINER_ROOT/etc/systemd/system/sockets.target.wants/"

# Enable journald service
mkdir -p "$CONTAINER_ROOT/etc/systemd/system/sysinit.target.wants"
ln -sf /usr/lib/systemd/system/systemd-journald.service "$CONTAINER_ROOT/etc/systemd/system/sysinit.target.wants/"

# Ensure the container root and key directories are world-traversable.
# mktemp -d creates the root with mode 700; any execve or path lookup by a non-root
# UID (via nsenter --setuid) fails immediately at '/' with EACCES before reaching
# /usr/bin/bash.  Expand permissions here rather than relying on umask.
# /etc is safe to open (shadow stays 600 due to its own chmod above).
chmod a+rX "$CONTAINER_ROOT"
chmod a+rX "$CONTAINER_ROOT/etc"
chmod a+rX "$CONTAINER_ROOT/home"
chmod a+rX "$CONTAINER_ROOT/run"
chmod 1777 "$CONTAINER_ROOT/tmp"
chmod -R a+rX "$CONTAINER_ROOT/usr"

log_info "Container setup complete: $CONTAINER_ROOT"
log_info "You can start the container with: systemd-nspawn -D $CONTAINER_ROOT -b"
