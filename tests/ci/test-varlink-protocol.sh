#!/bin/bash
# Advanced integration tests for varlink protocol communication

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-utils.sh"

log_info "========================================="
log_info "Varlink Protocol Integration Tests"
log_info "========================================="

# Test: Verify varlink sockets are accessible
test_varlink_sockets_ready() {
    log_test "Testing varlink socket accessibility"

    # Both sockets should exist and be Unix sockets
    container_exec test -S /run/account/pwaccess-socket
    assert_success $? "pwaccessd varlink socket exists"

    container_exec test -S /run/account/pwupd-socket
    assert_success $? "pwupdd varlink socket exists"
}

# Test: Socket ownership and permissions
test_socket_security() {
    log_test "Testing socket security attributes"

    # Sockets should be owned by root
    local pwaccess_owner=$(container_exec stat -c '%U' /run/account/pwaccess-socket)
    assert_equals "$pwaccess_owner" "root" "pwaccessd socket owned by root"

    local pwupd_owner=$(container_exec stat -c '%U' /run/account/pwupd-socket)
    assert_equals "$pwupd_owner" "root" "pwupdd socket owned by root"
}

# Test: Socket file descriptor naming
test_socket_fd_names() {
    log_test "Testing socket FileDescriptorName configuration"

    # Check unit configuration for FD names
    local pwaccess_fd=$(container_exec systemctl show pwaccessd.socket -p FileDescriptorName --value)
    assert_equals "$pwaccess_fd" "varlink" "pwaccessd socket FD name is 'varlink'"

    local pwupd_fd=$(container_exec systemctl show pwupdd.socket -p FileDescriptorName --value)
    assert_equals "$pwupd_fd" "varlink" "pwupdd socket FD name is 'varlink'"
}

# Test: Varlink GetInfo method
test_varlink_getinfo() {
    log_test "Testing varlink GetInfo method"

    # Test org.varlink.service.GetInfo on pwaccessd
    local pwaccess_info=$(container_exec varlinkctl info unix:/run/account/pwaccess-socket)
    assert_success $? "pwaccessd GetInfo call succeeded"
    assert_contains "$pwaccess_info" "org.openSUSE.pwaccess" "pwaccessd exposes pwaccess interface"

    # Test org.varlink.service.GetInfo on pwupdd
    local pwupd_info=$(container_exec varlinkctl info unix:/run/account/pwupd-socket)
    assert_success $? "pwupdd GetInfo call succeeded"
    assert_contains "$pwupd_info" "org.openSUSE.pwupd" "pwupdd exposes pwupd interface"
}

# Test: Concurrent connection simulation
test_concurrent_connection_readiness() {
    log_test "Testing concurrent connection handling readiness"

    # pwupdd should support multiple concurrent connections
    local max_conn=$(container_exec systemctl show pwupdd.socket -p MaxConnectionsPerSource --value)
    assert_equals "$max_conn" "16" "pwupdd configured for 16 concurrent connections"

    # Accept=yes means each connection gets its own service instance
    local accept=$(container_exec systemctl show pwupdd.socket -p Accept --value)
    assert_equals "$accept" "yes" "pwupdd uses Accept=yes for concurrent instances"

    log_info "Ready for concurrent connection testing"
    log_info "Future: Test actual concurrent varlink calls"
}

# Test: GetUserRecord method
test_getuserrecord() {
    log_test "Testing GetUserRecord method"

    # Create a test user
    create_test_user "varlinkuser" "TestPass123"

    # Test GetUserRecord for existing user
    local result=$(container_exec varlinkctl call unix:/run/account/pwaccess-socket org.openSUSE.pwaccess.GetUserRecord '{"userName":"varlinkuser"}')
    assert_success $? "GetUserRecord call succeeded"
    assert_contains "$result" '"name":"varlinkuser"' "Response contains username"
    assert_contains "$result" '"UID":' "Response contains UID"
    assert_contains "$result" '"GID":' "Response contains GID"

    # Test GetUserRecord for non-existent user
    local result_notfound=$(container_exec varlinkctl call unix:/run/account/pwaccess-socket org.openSUSE.pwaccess.GetUserRecord '{"userName":"nonexistent"}' 2>&1 || true)
    assert_contains "$result_notfound" '"Success":false' "GetUserRecord returns error for non-existent user"

    # Cleanup
    delete_test_user "varlinkuser"
}

# Test: VerifyPassword method
test_verifypassword() {
    log_test "Testing VerifyPassword method"

    # Create a test user
    create_test_user "pwverifyuser" "CorrectPass123"

    # Test with correct password
    local result_correct=$(container_exec varlinkctl call unix:/run/account/pwaccess-socket org.openSUSE.pwaccess.VerifyPassword '{"userName":"pwverifyuser","password":"CorrectPass123"}')
    assert_success $? "VerifyPassword succeeded with correct password"
    assert_contains "$result_correct" '"Success":true' "Password verified successfully"

    # Test with incorrect password
    local result_wrong=$(container_exec varlinkctl call unix:/run/account/pwaccess-socket org.openSUSE.pwaccess.VerifyPassword '{"userName":"pwverifyuser","password":"WrongPass"}' || true)
    assert_contains "$result_wrong" '"Success":false' "VerifyPassword returns false with wrong password"

    # Cleanup
    delete_test_user "pwverifyuser"
}

# Test: Chsh method
test_chsh() {
    log_test "Testing Chsh method"

    # Create a test user
    create_test_user "shelluser" "ShellPass123"

    # Change shell to /bin/sh
    local result=$(container_exec varlinkctl call unix:/run/account/pwupd-socket org.openSUSE.pwupd.Chsh '{"userName":"shelluser","shell":"/bin/sh"}')
    assert_success $? "Chsh call succeeded"

    # Verify shell was changed
    local shell=$(container_exec getent passwd shelluser | cut -d: -f7)
    assert_equals "$shell" "/bin/sh" "Shell changed to /bin/sh"

    # Cleanup
    delete_test_user "shelluser"
}

# Test: Chfn method
test_chfn() {
    log_test "Testing Chfn method"

    # Create a test user
    create_test_user "gecosuser" "GecosPass123"

    # Change GECOS field
    local result=$(container_exec varlinkctl call unix:/run/account/pwupd-socket org.openSUSE.pwupd.Chfn '{"userName":"gecosuser","fullName":"Test User","room":"Room 123","workPhone":"555-1234","homePhone":"555-5678"}')
    assert_success $? "Chfn call succeeded"

    # Verify GECOS was changed
    local gecos=$(container_exec getent passwd gecosuser | cut -d: -f5)
    assert_equals "$gecos" "Test User,Room 123,555-1234,555-5678" "GECOS field updated correctly"

    # Cleanup
    delete_test_user "gecosuser"
}

# Test: Error handling - invalid parameters
test_error_handling() {
    log_test "Testing error handling with invalid parameters"

    # Test with malformed JSON
    container_exec varlinkctl call unix:/run/account/pwaccess-socket org.openSUSE.pwaccess.GetUserRecord 'invalid json' 2>&1
    assert_not_equals $? 0 "Malformed JSON returns error"

    # Cleanup
    delete_test_user "erroruser"
}

# Run all tests
log_info "Starting varlink protocol tests"
echo ""

run_test test_varlink_sockets_ready
run_test test_socket_security
run_test test_socket_fd_names
run_test test_varlink_getinfo
run_test test_concurrent_connection_readiness
run_test test_getuserrecord
run_test test_verifypassword
run_test test_chsh
run_test test_chfn
run_test test_error_handling

# Print summary
print_summary
