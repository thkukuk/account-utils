#!/bin/bash
# Integration tests for pwupdd service

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-utils.sh"

log_info "========================================="
log_info "pwupdd Integration Tests"
log_info "========================================="

# Test 1: Socket activation
test_socket_activation() {
    log_test "Testing pwupdd socket activation"

    # Socket should exist
    if container_exec test -S /run/account/pwupd-socket; then
        assert_success 0 "pwupdd socket exists"
    else
        assert_failure 0 "pwupdd socket exists"
        return 1
    fi
}

# Test 2: Socket permissions
test_socket_permissions() {
    log_test "Testing pwupdd socket permissions"

    # Socket should be world-accessible (mode 0666)
    local perms=$(container_exec stat -c '%a' /run/account/pwupd-socket)
    assert_equals "$perms" "666" "Socket has correct permissions (666)"
}

# Test 3: Accept socket configuration
test_accept_socket() {
    log_test "Testing Accept=yes socket configuration"

    # Check socket unit configuration
    local accept_setting=$(container_exec systemctl show pwupdd.socket -p Accept --value)
    assert_equals "$accept_setting" "yes" "Socket has Accept=yes configured"
}

# Test 4: Socket directory permissions
test_socket_directory() {
    log_test "Testing socket directory"

    # Directory should exist
    container_exec test -d /run/account
    assert_success $? "/run/account directory exists"

    # Directory should have correct permissions (0755)
    local dir_perms=$(container_exec stat -c '%a' /run/account)
    assert_equals "$dir_perms" "755" "Socket directory has correct permissions (755)"
}

# Test 5: MaxConnectionsPerSource setting
test_max_connections() {
    log_test "Testing MaxConnectionsPerSource configuration"

    # Check the setting
    local max_conn=$(container_exec systemctl show pwupdd.socket -p MaxConnectionsPerSource --value)
    assert_equals "$max_conn" "16" "MaxConnectionsPerSource is set to 16"
}

# Test 6: User password change capability
test_password_change_setup() {
    log_test "Testing password change setup"

    # Create a test user
    create_test_user "pwtest1" "oldpass123"

    # Verify user exists
    local user_exists=$(container_exec getent passwd pwtest1 >/dev/null 2>&1 && echo "yes" || echo "no")
    assert_equals "$user_exists" "yes" "Test user for password change exists"

    # Cleanup
    delete_test_user "pwtest1"
}

# Test 7: Multiple concurrent connections (simulated)
test_concurrent_access() {
    log_test "Testing socket can handle connection setup"

    # Since pwupdd is an Accept=yes socket, each connection spawns a new instance
    # We verify the socket configuration allows this
    local socket_type=$(container_exec systemctl show pwupdd.socket -p Accept --value)
    assert_equals "$socket_type" "yes" "Socket configured for concurrent connections"
}

# Test 8: Service binary exists
test_service_binary() {
    log_test "Testing pwupdd binary availability"

    container_exec test -x /usr/libexec/pwupdd
    assert_success $? "pwupdd binary exists and is executable"
}

# Test 9: Varlink socket readiness
test_varlink_readiness() {
    log_test "Testing varlink socket readiness"

    # Socket should be a Unix socket
    local socket_type=$(container_exec stat -c '%F' /run/account/pwupd-socket)
    assert_equals "$socket_type" "socket" "pwupd-socket is a Unix socket"
}

# Test 10: Socket restart resilience
test_socket_restart() {
    log_test "Testing socket restart"

    # Restart socket
    container_exec systemctl restart pwupdd.socket
    assert_success $? "Socket restart succeeded"

    # Wait for socket to be ready
    sleep 2

    # Verify socket is available
    wait_for_socket "/run/account/pwupd-socket" 10
    assert_success $? "Socket is available after restart"
}

# Test 11: Service logging
test_service_logging() {
    log_test "Testing service logging"

    # Check if we can read journal for the socket
    container_exec journalctl -u pwupdd.socket --no-pager -n 5 >/dev/null
    assert_success $? "Can read socket logs"
}

# Test 12: Test user shell change preparation
test_shell_change_setup() {
    log_test "Testing shell change capability setup"

    # Create test user
    create_test_user "shelltest1" "testpass"

    # Verify user's shell is recorded
    local user_shell=$(container_exec getent passwd shelltest1 | cut -d: -f7)
    log_info "User shell: $user_shell"

    # Shell field should not be empty
    assert_not_equals "$user_shell" "" "User has a shell configured"

    # Cleanup
    delete_test_user "shelltest1"
}

# Test 13: Test GECOS field access
test_gecos_access() {
    log_test "Testing GECOS field accessibility"

    # Create test user with GECOS
    create_test_user "gecostest1" "testpass"

    # Read GECOS field
    local gecos=$(container_exec getent passwd gecostest1 | cut -d: -f5)
    log_info "GECOS field: '$gecos'"

    # GECOS field should exist (can be empty)
    container_exec getent passwd gecostest1 | cut -d: -f5 >/dev/null
    assert_success $? "GECOS field is accessible"

    # Cleanup
    delete_test_user "gecostest1"
}

# Run all tests
log_info "Starting pwupdd tests"
echo ""

run_test test_socket_activation
run_test test_socket_permissions
run_test test_accept_socket
run_test test_socket_directory
run_test test_max_connections
run_test test_password_change_setup
run_test test_concurrent_access
run_test test_service_binary
run_test test_varlink_readiness
run_test test_socket_restart
run_test test_service_logging
run_test test_shell_change_setup
run_test test_gecos_access

# Print summary
print_summary
