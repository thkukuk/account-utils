#!/bin/bash
# Common utilities for integration tests

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_test() {
    echo -e "${YELLOW}[TEST]${NC} $*"
}

# Container management
# These variables should be set by run-tests.sh
# Default values only for backward compatibility (deprecated)
if [ -z "$CONTAINER_ROOT" ]; then
    log_warn "CONTAINER_ROOT not set, using default (insecure)"
    CONTAINER_ROOT="/tmp/account-utils-test-container"
fi

if [ -z "$CONTAINER_NAME" ]; then
    log_warn "CONTAINER_NAME not set, using default"
    CONTAINER_NAME="account-utils-test"
fi

container_exec() {
    # Get the leader PID of the container
    local leader_pid=$(machinectl show -P Leader "$CONTAINER_NAME" 2>/dev/null)
    if [ -z "$leader_pid" ] || [ "$leader_pid" = "0" ]; then
        # Fallback: try to find via pgrep
        leader_pid=$(pgrep -f "systemd-nspawn.*$CONTAINER_NAME" | head -1)
        if [ -z "$leader_pid" ]; then
            log_error "Could not find container PID for $CONTAINER_NAME"
            return 1
        fi
    fi

    # For commands that might be bash builtins (like test, [, etc.), wrap in bash -c
    # This ensures builtins work even if they're not in /usr/bin
    if [ "$1" = "test" ] || [ "$1" = "[" ]; then
        # Quote all arguments properly for bash -c
        local cmd="$1"
        shift
        nsenter -t "$leader_pid" -m -p -n -- /usr/bin/bash -c "$cmd $(printf '%q ' "$@")"
    else
        # Use nsenter to execute command in container namespace
        nsenter -t "$leader_pid" -m -p -n -- "$@"
    fi
}

container_exec_user() {
    local user="$1"
    shift
    # Get the leader PID of the container
    local leader_pid=$(machinectl show -P Leader "$CONTAINER_NAME" 2>/dev/null)
    if [ -z "$leader_pid" ] || [ "$leader_pid" = "0" ]; then
        leader_pid=$(pgrep -f "systemd-nspawn.*$CONTAINER_NAME" | head -1)
        if [ -z "$leader_pid" ]; then
            log_error "Could not find container PID for $CONTAINER_NAME"
            return 1
        fi
    fi

    # Use nsenter with su to run as specific user
    nsenter -t "$leader_pid" -m -p -n -- su -s /bin/bash "$user" -c "$*"
}

wait_for_service() {
    local service="$1"
    local timeout="${2:-10}"
    local count=0

    log_info "Waiting for service: $service"
    while [ $count -lt "$timeout" ]; do
        if container_exec systemctl is-active --quiet "$service" 2>/dev/null; then
            log_info "Service $service is active"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    log_error "Service $service failed to start within ${timeout}s"
    return 1
}

wait_for_socket() {
    local socket_path="$1"
    local timeout="${2:-10}"
    local count=0

    log_info "Waiting for socket: $socket_path"
    while [ $count -lt "$timeout" ]; do
        # Use ls -la to check if socket exists (socket files show as 's' in permissions)
        if container_exec ls -la "$socket_path" 2>/dev/null | grep -q "^s"; then
            log_info "Socket $socket_path is ready"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    log_error "Socket $socket_path not found within ${timeout}s"
    return 1
}

# Test user management
create_test_user() {
    local username="$1"
    local password="$2"
    local uid="${3:-}"

    log_info "Creating test user: $username"

    if [ -n "$uid" ]; then
        container_exec useradd -m -u "$uid" "$username"
    else
        container_exec useradd -m "$username"
    fi

    if [ -n "$password" ]; then
        echo "$username:$password" | container_exec chpasswd
    fi
}

delete_test_user() {
    local username="$1"

    log_info "Deleting test user: $username"
    container_exec userdel -r "$username" 2>/dev/null || true
}

# Test assertions
assert_equals() {
    TESTS_RUN=$((TESTS_RUN + 1))
    local actual="$1"
    local expected="$2"
    local message="${3:-Assertion failed}"

    if [ "$actual" = "$expected" ]; then
        log_info "✓ $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "✗ $message"
        log_error "  Expected: $expected"
        log_error "  Actual:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_not_equals() {
    TESTS_RUN=$((TESTS_RUN + 1))
    local actual="$1"
    local expected="$2"
    local message="${3:-Assertion failed}"

    if [ "$actual" != "$expected" ]; then
        log_info "✓ $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "✗ $message"
        log_error "  Should not equal: $expected"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_success() {
    TESTS_RUN=$((TESTS_RUN + 1))
    local exit_code="$1"
    local message="${2:-Command should succeed}"

    if [ "$exit_code" -eq 0 ]; then
        log_info "✓ $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "✗ $message (exit code: $exit_code)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_failure() {
    TESTS_RUN=$((TESTS_RUN + 1))
    local exit_code="$1"
    local message="${2:-Command should fail}"

    if [ "$exit_code" -ne 0 ]; then
        log_info "✓ $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "✗ $message (command succeeded unexpectedly)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should contain substring}"

    if echo "$haystack" | grep -qF -- "$needle"; then
        log_info "✓ $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "✗ $message"
        log_error "  Looking for: $needle"
        log_error "  In: $haystack"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Run a test function
run_test() {
    local test_name="$1"
    log_test "Running: $test_name"

    if "$test_name"; then
        log_info "Test $test_name completed"
    else
        log_error "Test $test_name failed"
    fi
    echo ""
}

# Print test summary
print_summary() {
    echo ""
    echo "========================================="
    echo "Test Summary"
    echo "========================================="
    echo "Total tests run:    $TESTS_RUN"
    echo -e "${GREEN}Tests passed:${NC}       $TESTS_PASSED"
    echo -e "${RED}Tests failed:${NC}       $TESTS_FAILED"
    echo "========================================="

    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        return 1
    fi
}

# Cleanup function
cleanup_test_users() {
    log_info "Cleaning up test users"
    for user in testuser1 testuser2 testuser3 testadmin; do
        delete_test_user "$user" 2>/dev/null || true
    done
}

# Show recent journal logs for debugging
show_journal() {
    local lines="${1:-50}"
    local unit="${2:-}"

    log_info "Recent journal logs:"
    echo "========================================="

    if [ -n "$unit" ]; then
        container_exec journalctl -u "$unit" -n "$lines" --no-pager
    else
        container_exec journalctl -n "$lines" --no-pager
    fi

    echo "========================================="
}

# Show service status for debugging
show_service_status() {
    local service="$1"

    log_info "Status for service: $service"
    echo "========================================="
    container_exec systemctl status "$service" --no-pager || true
    echo ""
    log_info "Recent logs for: $service"
    container_exec journalctl -u "$service" -n 20 --no-pager || true
    echo "========================================="
}
