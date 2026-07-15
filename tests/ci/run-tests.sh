#!/bin/bash
# Main test runner for account-utils integration tests

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_ROOT/build}"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/test-run-$(date +%Y%m%d-%H%M%S).log}"

# Setup logging to both stdout/stderr and log file
exec > >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

# Create secure temporary directory if CONTAINER_ROOT not explicitly set
if [ -z "$CONTAINER_ROOT" ]; then
    CONTAINER_ROOT=$(mktemp -d -t account-utils-test.XXXXXXXXXX)
    TMPDIR_CREATED=1
else
    TMPDIR_CREATED=0
fi

# Generate unique container name to allow parallel runs
CONTAINER_NAME="account-utils-test-$$-$(date +%s)"

# Export for test-utils.sh
export CONTAINER_ROOT
export CONTAINER_NAME

source "$SCRIPT_DIR/test-utils.sh"

KEEP_CONTAINER=0
SPECIFIC_TEST=""
NSPAWN_PID=""

# Log start of test run
log_info "Test run started at $(date)"
log_info "Log file: $LOG_FILE"

# Function to cleanup (defined early so trap works for early failures)
cleanup() {
    local exit_code=$?

    log_info "Cleaning up"

    # Export journal logs before stopping container
    if [ -n "$CONTAINER_NAME" ] && machinectl status "$CONTAINER_NAME" >/dev/null 2>&1; then
        log_info "Exporting journal logs from container"

        # Export to main log file with both full journal and service-specific logs
        echo "" >> "$LOG_FILE"
        echo "=========================================" >> "$LOG_FILE"
        echo "Container Journal Logs (Full)" >> "$LOG_FILE"
        echo "=========================================" >> "$LOG_FILE"
        container_exec journalctl --no-pager --all >> "$LOG_FILE" 2>&1 || log_warn "Failed to export full journal"
        echo "" >> "$LOG_FILE"

        echo "=========================================" >> "$LOG_FILE"
        echo "pwaccessd Service Logs" >> "$LOG_FILE"
        echo "=========================================" >> "$LOG_FILE"
        container_exec journalctl -u pwaccessd.service --no-pager >> "$LOG_FILE" 2>&1 || true
        echo "" >> "$LOG_FILE"

        echo "=========================================" >> "$LOG_FILE"
        echo "pwupdd Service Logs" >> "$LOG_FILE"
        echo "=========================================" >> "$LOG_FILE"
        container_exec journalctl -u 'pwupdd@*' --no-pager >> "$LOG_FILE" 2>&1 || true
        echo "" >> "$LOG_FILE"

        echo "=========================================" >> "$LOG_FILE"
        echo "Socket Activation Logs" >> "$LOG_FILE"
        echo "=========================================" >> "$LOG_FILE"
        container_exec journalctl -u pwaccessd.socket -u pwupdd.socket --no-pager >> "$LOG_FILE" 2>&1 || true
        echo "=========================================" >> "$LOG_FILE"
    fi

    # Terminate container
    if [ -n "$CONTAINER_NAME" ] && machinectl status "$CONTAINER_NAME" >/dev/null 2>&1; then
        log_info "Stopping container: $CONTAINER_NAME"
        # Try graceful poweroff first
        machinectl poweroff "$CONTAINER_NAME" 2>/dev/null || true

        # Wait up to 5 seconds for graceful shutdown
        local wait_count=0
        while [ $wait_count -lt 5 ] && machinectl status "$CONTAINER_NAME" >/dev/null 2>&1; do
            sleep 1
            wait_count=$((wait_count + 1))
        done

        # If still running, force terminate
        if machinectl status "$CONTAINER_NAME" >/dev/null 2>&1; then
            log_warn "Container did not shut down gracefully, forcing termination"
            machinectl terminate "$CONTAINER_NAME" 2>/dev/null || true
            sleep 1
        fi
    fi

    # Force kill nspawn process if still running
    if [ -n "$NSPAWN_PID" ] && kill -0 "$NSPAWN_PID" 2>/dev/null; then
        log_info "Waiting for nspawn process to exit"
        # Give it 2 more seconds
        local wait_count=0
        while [ $wait_count -lt 2 ] && kill -0 "$NSPAWN_PID" 2>/dev/null; do
            sleep 1
            wait_count=$((wait_count + 1))
        done

        # Force kill if still alive
        if kill -0 "$NSPAWN_PID" 2>/dev/null; then
            log_warn "Force killing nspawn process $NSPAWN_PID"
            kill -9 "$NSPAWN_PID" 2>/dev/null || true
        fi

        # Final wait to reap the process
        wait $NSPAWN_PID 2>/dev/null || true
    fi

    # Remove container directory with safety checks
    if [ "$KEEP_CONTAINER" -eq 0 ]; then
        # Verify CONTAINER_ROOT is set and not empty
        if [ -z "$CONTAINER_ROOT" ]; then
            log_error "CONTAINER_ROOT is empty, refusing to delete"
            exit $exit_code
        fi

        # Verify path matches expected pattern (defense in depth)
        # Pattern: /tmp/account-utils-test.XXXXXXXXXX (10 random alphanumeric chars)
        if ! [[ "$CONTAINER_ROOT" =~ ^/tmp/account-utils-test\.[A-Za-z0-9]{10}$ ]]; then
            log_error "CONTAINER_ROOT path doesn't match expected pattern: $CONTAINER_ROOT"
            log_error "Expected: /tmp/account-utils-test.XXXXXXXXXX"
            log_error "Refusing to delete for safety"
            exit $exit_code
        fi

        # Verify we created this directory (if tracking variable exists)
        if [ -n "$TMPDIR_CREATED" ] && [ "$TMPDIR_CREATED" -ne 1 ]; then
            log_warn "TMPDIR_CREATED flag not set, directory may not have been created by this script"
            log_warn "Skipping deletion: $CONTAINER_ROOT"
            exit $exit_code
        fi

        # Verify directory exists and is a directory
        if [ ! -d "$CONTAINER_ROOT" ]; then
            log_warn "Container directory doesn't exist or is not a directory: $CONTAINER_ROOT"
        elif [ -L "$CONTAINER_ROOT" ]; then
            log_error "Container path is a symlink, refusing to delete: $CONTAINER_ROOT"
        else
            # Final safety check: verify ownership
            local owner
            owner=$(stat -c '%U' "$CONTAINER_ROOT" 2>/dev/null)
            if [ "$owner" != "root" ]; then
                log_error "Container directory not owned by root (owner: $owner), refusing to delete: $CONTAINER_ROOT"
            else
                log_info "Removing container directory: $CONTAINER_ROOT"
                rm -rf "${CONTAINER_ROOT:?}" || log_error "Failed to remove container directory"
            fi
        fi
    else
        log_info "Keeping container at: $CONTAINER_ROOT"
        log_info "Container name: $CONTAINER_NAME"
        log_info "To inspect: systemd-nspawn -D $CONTAINER_ROOT"
        log_info "Or: machinectl shell $CONTAINER_NAME"
        log_info "To cleanup later: sudo rm -rf $CONTAINER_ROOT"
    fi

    log_info "Test run ended at $(date)"

    # Flush output buffers before printing final log location
    sync

    log_info "Full log saved to: $LOG_FILE"

    exit $exit_code
}

# Register cleanup trap early to handle failures during setup
trap cleanup EXIT INT TERM

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep-container)
            KEEP_CONTAINER=1
            shift
            ;;
        --help|-h)
            cat << EOF
Usage: $0 [OPTIONS] [TEST_SUITE]

Run integration tests for account-utils in systemd-nspawn container.

OPTIONS:
    --keep-container    Don't remove container after tests
    --verbose, -v       Verbose output
    --help, -h          Show this help message

ENVIRONMENT:
    LOG_FILE           Path to log file (default: test-run-YYYYMMDD-HHMMSS.log)

TEST_SUITE:
    test-pwaccessd      Run only pwaccessd tests
    test-pwupdd         Run only pwupdd tests
    test-pam            Run only PAM tests
    (default: run all tests)

EXAMPLES:
    sudo ./run-tests.sh
    sudo ./run-tests.sh --keep-container test-pwaccessd
    sudo ./run-tests.sh -v test-pwupdd

EOF
            exit 0
            ;;
        test-*)
            SPECIFIC_TEST="$1"
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root (for systemd-nspawn)"
    exit 1
fi

# Build the project if needed
log_info "Checking build"
if [ ! -d "$BUILD_DIR" ]; then
    log_info "Build directory not found, building project"
    cd "$PROJECT_ROOT"
    meson setup "$BUILD_DIR"
    ninja -C "$BUILD_DIR"
else
    log_info "Rebuilding project"
    ninja -C "$BUILD_DIR"
fi

if [ ! -e /usr/bin/machinectl ]; then
    log_error "machinectl not found!"
    exit 1;
fi
if [ ! -e /usr/bin/systemd-nspawn ]; then
    log_error "systemd-nspawn not found!"
    exit 1;
fi

# Setup container
log_info "Setting up test container"
"$SCRIPT_DIR/setup-container.sh"

# Start container
log_info "Starting container: $CONTAINER_NAME"

# Stop any existing container with the same name
machinectl terminate "$CONTAINER_NAME" 2>/dev/null || true
sleep 1

# Start the container in the background
systemd-nspawn -D "$CONTAINER_ROOT" \
    --machine="$CONTAINER_NAME" \
    --boot \
    --notify-ready=yes \
    --suppress-sync=yes \
    --register=yes \
    --keep-unit \
    --quiet \
    &

NSPAWN_PID=$!

# Wait for container to be ready
log_info "Waiting for container to boot"
sleep 3

# Check if container is running
if ! machinectl status "$CONTAINER_NAME" >/dev/null 2>&1; then
    log_error "Container failed to start"
    wait $NSPAWN_PID || true
    exit 1
fi

log_info "Container is running"

# Wait for services to be ready
sleep 2

# Check if sockets are available
log_info "Checking if services are ready"
if ! wait_for_socket "/run/account/pwaccess-socket" 15; then
    log_error "pwaccessd socket not ready"
    container_exec journalctl -u pwaccessd.socket --no-pager || true
    exit 1
fi

if ! wait_for_socket "/run/account/pwupd-socket" 15; then
    log_error "pwupdd socket not ready"
    container_exec journalctl -u pwupdd.socket --no-pager || true
    exit 1
fi

log_info "Services are ready"

# Run tests
ALL_TESTS_PASSED=0
FAILED_SUITES=()

if [ -z "$SPECIFIC_TEST" ]; then
    # Run all tests
    for test_script in "$SCRIPT_DIR"/test-*.sh; do
        if [ -f "$test_script" ] && [ "$test_script" != "$SCRIPT_DIR/test-utils.sh" ]; then
            log_info "Running test suite: $(basename "$test_script")"
            if bash "$test_script"; then
                log_info "✓ Test suite passed: $(basename "$test_script")"
            else
                log_error "✗ Test suite failed: $(basename "$test_script")"
                ALL_TESTS_PASSED=1
                FAILED_SUITES+=("$(basename "$test_script")")
            fi
            echo ""
        fi
    done
else
    # Run specific test
    test_script="$SCRIPT_DIR/${SPECIFIC_TEST}.sh"
    if [ ! -f "$test_script" ]; then
        log_error "Test script not found: $test_script"
        exit 1
    fi

    log_info "Running test suite: $SPECIFIC_TEST"
    if bash "$test_script"; then
        log_info "✓ Test suite passed"
    else
        log_error "✗ Test suite failed"
        ALL_TESTS_PASSED=1
        FAILED_SUITES+=("$SPECIFIC_TEST")
    fi
fi

# Print final summary
echo ""
echo "========================================="
echo "Integration Test Results"
echo "========================================="

if [ $ALL_TESTS_PASSED -eq 0 ]; then
    echo -e "${GREEN}All test suites passed!${NC}"
else
    echo -e "${RED}Some test suites failed!${NC}"
    for failed_suite in "${FAILED_SUITES[@]}"; do
        echo -e "${RED}  ✗ ${failed_suite}${NC}"
    done
fi

echo "========================================="

exit $ALL_TESTS_PASSED
