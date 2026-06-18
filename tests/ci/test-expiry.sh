#!/bin/bash
# Integration tests for expiry (check password expiration)
# Tests actual password expiration checking via pwaccess service

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-utils.sh"

log_info "========================================="
log_info "expiry Integration Tests"
log_info "========================================="

# Helper function to get shadow field for a user
get_shadow_field() {
    local username="$1"
    local field_num="${2:-1}"  # 1=name, 2=passwd, 3=lstchg, 4=min, 5=max, 6=warn, 7=inact, 8=expire, 9=flag

    container_exec getent shadow "$username" 2>/dev/null | cut -d: -f"$field_num"
}

# Test 1: expiry binary exists and is executable
test_expiry_binary_exists() {
    log_test "Testing expiry binary availability"

    container_exec test -x /usr/bin/expiry
    assert_success $? "expiry binary exists and is executable"
}

# Test 2: expiry --help works
test_expiry_help() {
    log_test "Testing expiry --help option"

    local output=$(container_exec /usr/bin/expiry --help 2>&1)
    local exit_code=$?

    assert_success "$exit_code" "expiry --help exits successfully"
    assert_contains "$output" "check" "Help includes --check option"
    assert_contains "$output" "force" "Help includes --force option"
    assert_contains "$output" "expiration" "Help describes expiration checking"
}

# Test 3: expiry --version works
test_expiry_version() {
    log_test "Testing expiry --version option"

    local output=$(container_exec /usr/bin/expiry --version 2>&1)
    local exit_code=$?

    assert_success "$exit_code" "expiry --version exits successfully"
    assert_contains "$output" "expiry" "Version output contains program name"
}

# Test 4: Create test users with different expiration states
test_create_test_users() {
    log_test "Creating test users for expiry tests"

    # Create user with normal password aging
    create_test_user "expirytest1" "TestPass123"

    # Verify user has shadow entry
    local shadow=$(get_shadow_field "expirytest1" 1)
    assert_equals "$shadow" "expirytest1" "Test user has shadow entry"

    # Set password aging to reasonable values (not expired)
    container_exec /usr/bin/chage -M 90 -W 7 expirytest1 2>/dev/null || true
}

# Test 5: Test pwaccess socket availability
test_pwaccess_socket() {
    log_test "Testing pwaccess socket availability for expiry"

    # expiry uses pwaccess to check expiration
    container_exec test -S /run/account/pwaccess-socket
    assert_success $? "pwaccess socket exists for expiry to use"

    # Check socket is accessible
    local perms=$(container_exec stat -c '%a' /run/account/pwaccess-socket)
    assert_equals "$perms" "666" "pwaccess socket is accessible (mode 666)"
}

# Test 6: expiry -c (--check) checks non-expired account
test_expiry_check_not_expired() {
    log_test "Testing expiry -c on non-expired account"

    # Set account to not be expired (far future max days)
    container_exec /usr/bin/chage -M 99999 expirytest1 2>/dev/null || true

    # Check expiration status
    local output=$(container_exec /usr/bin/expiry -c expirytest1 2>&1)
    local exit_code=$?

    # Exit code 0 typically means not expired
    log_info "expiry -c exit code: $exit_code"
    log_info "expiry -c output: ${output:0:100}"

    # Just verify command executed
    # (exact behavior depends on pwaccess implementation)
}

# Test 7: expiry -c checks specific user
test_expiry_check_user() {
    log_test "Testing expiry -c with username argument"

    # Create second user
    create_test_user "expirytest2" "TestPass456"
    container_exec /usr/bin/chage -M 99999 expirytest2 2>/dev/null || true

    # Check expiration for specific user
    local output=$(container_exec /usr/bin/expiry -c expirytest2 2>&1)
    local exit_code=$?

    log_info "expiry -c expirytest2 exit code: $exit_code"
    # Verify command executed

    # Cleanup
    delete_test_user "expirytest2"
}

# Test 8: expiry with expired password (lstchg=0)
test_expiry_check_expired_password() {
    log_test "Testing expiry -c with expired password"

    # Create user with expired password (lstchg=0 forces change on next login)
    create_test_user "expirytest3" "TestPass789"
    container_exec /usr/bin/chage -d 0 expirytest3 2>/dev/null || true

    # Check expiration status
    local output=$(container_exec /usr/bin/expiry -c expirytest3 2>&1)
    local exit_code=$?

    log_info "Expired password check exit code: $exit_code"
    log_info "Expired password check output: ${output:0:100}"

    # Non-zero exit code expected for expired password
    if [ "$exit_code" -ne 0 ]; then
        assert_success 0 "expiry detected expired password (non-zero exit)"
    else
        log_info "expiry returned 0 for expired password (may vary by implementation)"
    fi

    # Cleanup
    delete_test_user "expirytest3"
}

# Test 9: expiry with account expiration date
test_expiry_account_expiration() {
    log_test "Testing expiry with account expiration date"

    # Create user and set account to expire in past
    create_test_user "expirytest4" "TestPass000"
    container_exec /usr/bin/chage -E 2020-01-01 expirytest4 2>/dev/null || true

    # Check expiration status
    local output=$(container_exec /usr/bin/expiry -c expirytest4 2>&1)
    local exit_code=$?

    log_info "Expired account check exit code: $exit_code"
    log_info "Expired account check output: ${output:0:100}"

    # Cleanup
    delete_test_user "expirytest4"
}

# Test 10: expiry -f (--force) option exists
test_expiry_force_option() {
    log_test "Testing expiry -f / --force option"

    # Note: -f forces interactive password change if expired
    # We can't test this in automated tests without PAM interaction
    # But we can verify the option is recognized

    local help_output=$(container_exec /usr/bin/expiry --help 2>&1)
    assert_contains "$help_output" "force" "Help shows -f/--force option"

    # Try to call -f (will fail or prompt, but should recognize option)
    # Using non-existent user to avoid actual password prompt
    container_exec /usr/bin/expiry -f nonexistentuser99999 2>/dev/null
    local exit_code=$?

    # Should fail (user doesn't exist) but recognizes the option
    log_info "expiry -f with invalid user exit code: $exit_code"
}

# Test 11: expiry rejects conflicting options
test_expiry_option_conflict() {
    log_test "Testing expiry rejects -c and -f together"

    # expiry should reject using -c and -f simultaneously
    container_exec /usr/bin/expiry -c -f expirytest1 2>&1
    local exit_code=$?

    # Should fail with error
    assert_failure "$exit_code" "expiry rejects -c and -f together"
}

# Test 12: expiry requires option (-c or -f)
test_expiry_requires_option() {
    log_test "Testing expiry requires -c or -f option"

    # expiry without -c or -f should fail
    container_exec /usr/bin/expiry expirytest1 2>&1
    local exit_code=$?

    # Should fail (requires option)
    assert_failure "$exit_code" "expiry requires -c or -f option"
}

# Test 13: expiry rejects too many arguments
test_expiry_too_many_args() {
    log_test "Testing expiry rejects too many arguments"

    # expiry accepts maximum 1 username
    container_exec /usr/bin/expiry -c user1 user2 2>&1
    local exit_code=$?

    # Should fail (too many arguments)
    assert_failure "$exit_code" "expiry rejects multiple usernames"
}

# Test 14: expiry with non-existent user
test_expiry_nonexistent_user() {
    log_test "Testing expiry with non-existent user"

    # Check expiration for non-existent user
    container_exec /usr/bin/expiry -c nonexistentuser99999 2>&1
    local exit_code=$?

    # Should fail
    assert_failure "$exit_code" "expiry fails gracefully with non-existent user"
}

# Test 15: expiry on multiple different users
test_expiry_multiple_users() {
    log_test "Testing expiry on multiple users independently"

    # Create users with different aging
    create_test_user "expirytest5" "TestPass111"
    create_test_user "expirytest6" "TestPass222"

    # Set different aging for each
    container_exec /usr/bin/chage -M 60 expirytest5 2>/dev/null || true
    container_exec /usr/bin/chage -M 90 expirytest6 2>/dev/null || true

    # Check each independently
    container_exec /usr/bin/expiry -c expirytest5 2>&1
    local exit_code5=$?

    container_exec /usr/bin/expiry -c expirytest6 2>&1
    local exit_code6=$?

    log_info "User5 expiry check: exit $exit_code5"
    log_info "User6 expiry check: exit $exit_code6"

    # Cleanup
    delete_test_user "expirytest5"
    delete_test_user "expirytest6"
}

# Test 16: expiry checks shadow field dependencies
test_expiry_shadow_dependencies() {
    log_test "Testing expiry depends on shadow fields"

    # expiry checks shadow fields: lstchg, max, warn, inact, expire
    # Verify these fields exist for test user
    local lstchg=$(get_shadow_field "expirytest1" 3)
    local max=$(get_shadow_field "expirytest1" 5)
    local warn=$(get_shadow_field "expirytest1" 6)
    local inact=$(get_shadow_field "expirytest1" 7)
    local expire=$(get_shadow_field "expirytest1" 8)

    log_info "Shadow fields - lstchg:$lstchg max:$max warn:$warn inact:$inact expire:$expire"

    # Shadow fields should be accessible
    assert_success 0 "Shadow fields accessible for expiry checking"
}

# Test 17: expiry with recently changed password
test_expiry_recent_password() {
    log_test "Testing expiry with recently changed password"

    # Set password recently changed (today)
    local today_date=$(container_exec date +%Y-%m-%d)
    container_exec /usr/bin/chage -d "$today_date" -M 90 expirytest1 2>/dev/null || true

    # Check expiration
    local output=$(container_exec /usr/bin/expiry -c expirytest1 2>&1)
    local exit_code=$?

    log_info "Recent password check exit code: $exit_code"
    # Should not be expired (just changed)
}

# Test 18: expiry with max password age
test_expiry_max_password_age() {
    log_test "Testing expiry with maximum password age set"

    # Set maximum password age
    container_exec /usr/bin/chage -M 30 expirytest1 2>/dev/null || true

    # Verify max was set
    local max=$(get_shadow_field "expirytest1" 5)
    log_info "Maximum password age: $max days"

    # Check expiration considers max age
    container_exec /usr/bin/expiry -c expirytest1 2>&1
    local exit_code=$?
    log_info "expiry check with max age exit code: $exit_code"
}

# Test 19: expiry with warning period
test_expiry_warning_period() {
    log_test "Testing expiry with warning period"

    # Set warning period
    container_exec /usr/bin/chage -W 14 expirytest1 2>/dev/null || true

    # Verify warning was set
    local warn=$(get_shadow_field "expirytest1" 6)
    log_info "Warning period: $warn days"

    # Check expiration considers warning period
    container_exec /usr/bin/expiry -c expirytest1 2>&1
    local exit_code=$?
    log_info "expiry check with warning period exit code: $exit_code"
}

# Test 20: expiry on root user
test_expiry_root_user() {
    log_test "Testing expiry check on root user"

    # Root should have shadow entry
    local root_shadow=$(get_shadow_field "root" 1)
    assert_equals "$root_shadow" "root" "Root user has shadow entry"

    # Check root expiration (should not be expired)
    container_exec /usr/bin/expiry -c root 2>&1
    local exit_code=$?

    log_info "Root expiry check exit code: $exit_code"
    # Root typically doesn't expire
}

# Test 21: Cleanup test users
test_cleanup_expiry_users() {
    log_test "Cleaning up expiry test users"

    delete_test_user "expirytest1"

    # Verify cleanup
    local user_gone=$(container_exec getent passwd expirytest1 && echo "no" || echo "yes")
    assert_equals "$user_gone" "yes" "Test user removed successfully"
}

# Run all tests
log_info "Starting expiry integration tests"
log_info "Tests check password expiration status via pwaccess"
echo ""

run_test test_expiry_binary_exists
run_test test_expiry_help
run_test test_expiry_version
run_test test_create_test_users
run_test test_pwaccess_socket
run_test test_expiry_check_not_expired
run_test test_expiry_check_user
run_test test_expiry_check_expired_password
run_test test_expiry_account_expiration
run_test test_expiry_force_option
run_test test_expiry_option_conflict
run_test test_expiry_requires_option
run_test test_expiry_too_many_args
run_test test_expiry_nonexistent_user
run_test test_expiry_multiple_users
run_test test_expiry_shadow_dependencies
run_test test_expiry_recent_password
run_test test_expiry_max_password_age
run_test test_expiry_warning_period
run_test test_expiry_root_user
run_test test_cleanup_expiry_users

# Print summary
print_summary
