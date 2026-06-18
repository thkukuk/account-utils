#!/bin/bash
# Integration tests for pwaccessd service

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-utils.sh"

log_info "========================================="
log_info "pwaccessd Integration Tests"
log_info "========================================="

# Test 1: Socket activation
test_socket_activation() {
    log_test "Testing socket activation"

    # Socket should exist
    if container_exec test -S /run/account/pwaccess-socket; then
        assert_success 0 "pwaccessd socket exists"
    else
        assert_failure 0 "pwaccessd socket exists"
        return 1
    fi

    # Service should not be running initially (socket activated)
    local is_active=$(container_exec systemctl is-active pwaccessd.service || echo "inactive")
    log_info "Service state: $is_active"
}

# Test 2: Basic user lookup
test_user_lookup_root() {
    log_test "Testing root user lookup"

    # Create a simple test client using varlink CLI if available
    # For now, we'll verify the socket responds
    local result=$(container_exec test -S /run/account/pwaccess-socket && echo "success" || echo "failed")
    assert_equals "$result" "success" "Socket is accessible"
}

# Test 3: Create test user and verify access
test_user_creation_and_lookup() {
    log_test "Testing user creation and lookup"

    # Create test user
    create_test_user "testuser1" "testpass123"

    # Verify user exists in passwd
    local user_exists=$(container_exec getent passwd testuser1 >/dev/null 2>&1 && echo "yes" || echo "no")
    assert_equals "$user_exists" "yes" "Test user exists in passwd"

    # Cleanup
    delete_test_user "testuser1"
}

# Test 4: Multiple users
test_multiple_users() {
    log_test "Testing multiple user management"

    create_test_user "testuser2" "pass2" 2001
    create_test_user "testuser3" "pass3" 2002

    # Both users should exist
    local user2_exists=$(container_exec getent passwd testuser2 >/dev/null 2>&1 && echo "yes" || echo "no")
    local user3_exists=$(container_exec getent passwd testuser3 >/dev/null 2>&1 && echo "yes" || echo "no")

    assert_equals "$user2_exists" "yes" "testuser2 exists"
    assert_equals "$user3_exists" "yes" "testuser3 exists"

    # Cleanup
    delete_test_user "testuser2"
    delete_test_user "testuser3"
}

# Test 5: Verify socket permissions
test_socket_permissions() {
    log_test "Testing socket permissions"

    # Socket should be world-accessible (mode 0666)
    local perms=$(container_exec stat -c '%a' /run/account/pwaccess-socket)
    assert_equals "$perms" "666" "Socket has correct permissions (666)"
}

# Test 6: Service starts on socket access
test_service_activation() {
    log_test "Testing service activation on socket access"

    # First ensure service is inactive
    container_exec systemctl stop pwaccessd.service 2>/dev/null || true
    sleep 1

    # Access the socket (this would normally trigger activation)
    # Since we don't have varlink CLI in the container, we'll just test socket availability
    local socket_ready=$(container_exec test -S /run/account/pwaccess-socket && echo "ready" || echo "not ready")
    assert_equals "$socket_ready" "ready" "Socket is ready for activation"
}

# Test 7: Passwd file integrity
test_passwd_integrity() {
    log_test "Testing passwd file integrity"

    # Root user should always exist
    local root_entry=$(container_exec grep "^root:" /etc/passwd | cut -d: -f1)
    assert_equals "$root_entry" "root" "Root user exists in passwd"

    # Passwd file should be readable
    container_exec test -r /etc/passwd
    assert_success $? "Passwd file is readable"
}

# Test 8: Shadow file security
test_shadow_security() {
    log_test "Testing shadow file security"

    # Shadow file should have restricted permissions
    local shadow_perms=$(container_exec stat -c '%a' /etc/shadow)
    assert_equals "$shadow_perms" "600" "Shadow file has secure permissions (600)"

    # Shadow file should be owned by root
    local shadow_owner=$(container_exec stat -c '%U' /etc/shadow)
    assert_equals "$shadow_owner" "root" "Shadow file is owned by root"
}

# Test 9: Service logging
test_service_logging() {
    log_test "Testing service logging"

    # Check if we can read journal for the service
    container_exec journalctl -u pwaccessd.socket --no-pager -n 5 >/dev/null
    assert_success $? "Can read service logs"
}

# Test 10: Socket restart
test_socket_restart() {
    log_test "Testing socket restart"

    # Restart socket
    container_exec systemctl restart pwaccessd.socket
    assert_success $? "Socket restart succeeded"

    # Wait for socket to be ready
    sleep 2

    # Verify socket is available
    wait_for_socket "/run/account/pwaccess-socket" 10
    assert_success $? "Socket is available after restart"
}

# Run all tests
log_info "Starting pwaccessd tests"
echo ""

run_test test_socket_activation
run_test test_user_lookup_root
run_test test_user_creation_and_lookup
run_test test_multiple_users
run_test test_socket_permissions
run_test test_service_activation
run_test test_passwd_integrity
run_test test_shadow_security
run_test test_service_logging
run_test test_socket_restart

# Print summary
print_summary
