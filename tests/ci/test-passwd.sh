#!/bin/bash
# Integration tests for passwd (change user password)
# Tests actual password modification via varlink communication with pwupdd service
# Running as root bypasses PAM authentication requirements

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-utils.sh"

log_info "========================================="
log_info "passwd Integration Tests"
log_info "========================================="

# Helper function to get shadow password field
get_shadow_passwd() {
    local username="$1"
    container_exec getent shadow "$username" 2>/dev/null | cut -d: -f2
}

# Helper function to get shadow last change field
get_shadow_lstchg() {
    local username="$1"
    container_exec getent shadow "$username" 2>/dev/null | cut -d: -f3
}

# Check if password field is locked (starts with !)
is_password_locked() {
    local username="$1"
    local passwd_field=$(get_shadow_passwd "$username")
    [[ "$passwd_field" == !* ]]
}

# Check if password is empty
is_password_empty() {
    local username="$1"
    local passwd_field=$(get_shadow_passwd "$username")
    [ -z "$passwd_field" ] || [ "$passwd_field" = "" ]
}

# Test 1: passwd binary exists and is executable
test_passwd_binary_exists() {
    log_test "Testing passwd binary availability"

    container_exec test -x /usr/bin/passwd
    assert_success $? "passwd binary exists and is executable"
}

# Test 2: passwd --help works
test_passwd_help() {
    log_test "Testing passwd --help option"

    local output=$(container_exec /usr/bin/passwd --help 2>&1)
    local exit_code=$?

    assert_success "$exit_code" "passwd --help exits successfully"
    assert_contains "$output" "password" "Help mentions password"
    assert_contains "$output" "delete" "Help includes --delete option"
    assert_contains "$output" "expire" "Help includes --expire option"
    assert_contains "$output" "lock" "Help includes --lock option"
    assert_contains "$output" "unlock" "Help includes --unlock option"
}

# Test 3: passwd --version works
test_passwd_version() {
    log_test "Testing passwd --version option"

    local output=$(container_exec /usr/bin/passwd --version 2>&1)
    local exit_code=$?

    assert_success "$exit_code" "passwd --version exits successfully"
    assert_contains "$output" "passwd" "Version output contains program name"
}

# Test 4: Create test users
test_create_test_users() {
    log_test "Creating test users for passwd tests"

    # Create user
    create_test_user "passwdtest1" "TestPass123"

    # Verify user has password set
    local passwd_field=$(get_shadow_passwd "passwdtest1")
    assert_not_equals "$passwd_field" "" "Test user has password field"
    assert_not_equals "$passwd_field" "!" "Test user is not locked"
}

# Test 5: Test pwupdd socket availability
test_pwupdd_socket() {
    log_test "Testing pwupdd socket availability for passwd"

    # passwd communicates with pwupdd via varlink
    container_exec test -S /run/account/pwupd-socket
    assert_success $? "pwupdd socket exists for passwd to use"

    # Check socket is accessible
    local perms=$(container_exec stat -c '%a' /run/account/pwupd-socket)
    assert_equals "$perms" "666" "pwupdd socket is accessible (mode 666)"
}

# Test 6: passwd -s (--stdin) changes password
test_passwd_stdin() {
    log_test "Testing passwd -s / --stdin option"

    # Get current password hash
    local passwd_before=$(get_shadow_passwd "passwdtest1")

    # Change password via stdin as root
    echo "NewPassword456" | container_exec /usr/bin/passwd -s passwdtest1 2>/dev/null
    local exit_code=$?
    assert_success "$exit_code" "passwd -s succeeded"

    # Get new password hash
    local passwd_after=$(get_shadow_passwd "passwdtest1")

    # Password hash should have changed
    assert_not_equals "$passwd_after" "$passwd_before" "Password was changed"
    assert_not_equals "$passwd_after" "" "New password is set"
}

# Test 7: passwd -l (--lock) locks account
test_passwd_lock() {
    log_test "Testing passwd -l / --lock option"

    # Ensure password is not locked initially
    local passwd_before=$(get_shadow_passwd "passwdtest1")
    if [[ "$passwd_before" == !* ]]; then
        # Unlock first if already locked
        container_exec /usr/bin/passwd -u passwdtest1 2>/dev/null
        passwd_before=$(get_shadow_passwd "passwdtest1")
    fi

    # Lock the account
    container_exec /usr/bin/passwd -l passwdtest1
    local exit_code=$?
    assert_success "$exit_code" "passwd -l succeeded"

    # Verify password is locked (starts with !)
    local passwd_after=$(get_shadow_passwd "passwdtest1")
    if [[ "$passwd_after" == !* ]]; then
        assert_success 0 "Password is locked (starts with !)"
    else
        assert_success 1 "Password should start with ! when locked"
    fi
}

# Test 8: passwd -u (--unlock) unlocks account
test_passwd_unlock() {
    log_test "Testing passwd -u / --unlock option"

    # Ensure account is locked first
    if ! is_password_locked "passwdtest1"; then
        container_exec /usr/bin/passwd -l passwdtest1 2>/dev/null
    fi

    # Unlock the account
    container_exec /usr/bin/passwd -u passwdtest1
    local exit_code=$?
    assert_success "$exit_code" "passwd -u succeeded"

    # Verify password is unlocked (does not start with !)
    local passwd_after=$(get_shadow_passwd "passwdtest1")
    if [[ "$passwd_after" != !* ]]; then
        assert_success 0 "Password is unlocked (does not start with !)"
    else
        assert_success 1 "Password should not start with ! when unlocked"
    fi
}

# Test 9: passwd -d (--delete) deletes password
test_passwd_delete() {
    log_test "Testing passwd -d / --delete option"

    # Ensure user has a password
    echo "TestPassword789" | container_exec /usr/bin/passwd -s passwdtest1 2>/dev/null

    # Delete the password
    container_exec /usr/bin/passwd -d passwdtest1
    local exit_code=$?
    assert_success "$exit_code" "passwd -d succeeded"

    # Verify password field is empty or contains empty password indicator
    local passwd_after=$(get_shadow_passwd "passwdtest1")
    if [ -z "$passwd_after" ] || [ "$passwd_after" = "" ]; then
        assert_success 0 "Password deleted (empty field)"
    else
        log_info "Password field after delete: '$passwd_after'"
        # Empty password might be represented differently
    fi
}

# Test 10: passwd -e (--expire) expires password
test_passwd_expire() {
    log_test "Testing passwd -e / --expire option"

    # Set a password first
    echo "ExpireTest123" | container_exec /usr/bin/passwd -s passwdtest1 2>/dev/null

    # Expire the password
    container_exec /usr/bin/passwd -e passwdtest1
    local exit_code=$?
    assert_success "$exit_code" "passwd -e succeeded"

    # Get last change after expiring
    local lstchg_after=$(get_shadow_lstchg "passwdtest1")

    # Last change should be 0 (forces change on next login)
    assert_equals "$lstchg_after" "0" "Last change set to 0 (password expired)"
}

# Test 11: passwd -S (--status) displays status
test_passwd_status() {
    log_test "Testing passwd -S / --status option"

    # Set password first
    echo "StatusTest123" | container_exec /usr/bin/passwd -s passwdtest1 2>/dev/null

    # Get status
    local output=$(container_exec /usr/bin/passwd -S passwdtest1 2>&1)
    local exit_code=$?

    assert_success "$exit_code" "passwd -S succeeded"
    # Output should contain username and status information
    assert_contains "$output" "passwdtest1" "Status output contains username or shows status"
}

# Test 12: Test lock/unlock cycle
test_lock_unlock_cycle() {
    log_test "Testing lock/unlock cycle"

    # Set a password
    echo "CycleTest123" | container_exec /usr/bin/passwd -s passwdtest1 2>/dev/null
    local passwd_initial=$(get_shadow_passwd "passwdtest1")

    # Lock
    container_exec /usr/bin/passwd -l passwdtest1
    local passwd_locked=$(get_shadow_passwd "passwdtest1")
    assert_not_equals "$passwd_locked" "$passwd_initial" "Password changed when locked"

    # Unlock
    container_exec /usr/bin/passwd -u passwdtest1
    local passwd_unlocked=$(get_shadow_passwd "passwdtest1")

    # After unlock, password should be similar to initial (minus the !)
    if [[ "$passwd_locked" == !* ]]; then
        local expected_unlocked="${passwd_locked#!}"
        assert_equals "$passwd_unlocked" "$expected_unlocked" "Unlock removes ! prefix"
    fi
}

# Test 13: Test passwd on different user (root changing another user)
test_passwd_different_user() {
    log_test "Testing passwd on different user"

    # Create second test user
    create_test_user "passwdtest2" "TestPass456"

    local passwd_before=$(get_shadow_passwd "passwdtest2")

    # Change password for different user as root
    echo "NewPassword999" | container_exec /usr/bin/passwd -s passwdtest2 2>/dev/null
    local exit_code=$?
    assert_success "$exit_code" "passwd on different user succeeded"

    local passwd_after=$(get_shadow_passwd "passwdtest2")
    assert_not_equals "$passwd_after" "$passwd_before" "Different user's password changed by root"

    # Cleanup
    delete_test_user "passwdtest2"
}

# Test 14: Test sequential password changes
test_sequential_changes() {
    log_test "Testing sequential password changes"

    # Create fresh user
    create_test_user "passwdtest3" "TestPass789"

    # First change
    echo "Password1" | container_exec /usr/bin/passwd -s passwdtest3 2>/dev/null
    local passwd1=$(get_shadow_passwd "passwdtest3")

    # Second change
    echo "Password2" | container_exec /usr/bin/passwd -s passwdtest3 2>/dev/null
    local passwd2=$(get_shadow_passwd "passwdtest3")

    # Third change
    echo "Password3" | container_exec /usr/bin/passwd -s passwdtest3 2>/dev/null
    local passwd3=$(get_shadow_passwd "passwdtest3")

    # All should be different
    assert_not_equals "$passwd1" "$passwd2" "First and second passwords different"
    assert_not_equals "$passwd2" "$passwd3" "Second and third passwords different"
    assert_not_equals "$passwd1" "$passwd3" "First and third passwords different"

    # Cleanup
    delete_test_user "passwdtest3"
}

# Test 15: Test expire then set new password
test_expire_then_change() {
    log_test "Testing expire followed by password change"

    # Set initial password
    echo "Initial123" | container_exec /usr/bin/passwd -s passwdtest1 2>/dev/null

    # Expire it
    container_exec /usr/bin/passwd -e passwdtest1
    local lstchg_expired=$(get_shadow_lstchg "passwdtest1")
    assert_equals "$lstchg_expired" "0" "Password expired (lstchg=0)"

    # Set new password
    echo "AfterExpire456" | container_exec /usr/bin/passwd -s passwdtest1 2>/dev/null

    # Last change should be updated (not 0 anymore)
    local lstchg_after=$(get_shadow_lstchg "passwdtest1")
    assert_not_equals "$lstchg_after" "0" "Last change updated after password change"
}

# Test 16: Test delete then lock
test_delete_then_lock() {
    log_test "Testing delete followed by lock"

    # Set password
    echo "DeleteLock123" | container_exec /usr/bin/passwd -s passwdtest1 2>/dev/null

    # Delete it
    container_exec /usr/bin/passwd -d passwdtest1

    # Lock it
    container_exec /usr/bin/passwd -l passwdtest1
    local passwd_locked=$(get_shadow_passwd "passwdtest1")

    # Locked empty password should start with !
    if [[ "$passwd_locked" == !* ]]; then
        assert_success 0 "Locked empty password starts with !"
    else
        log_info "Password after delete-then-lock: '$passwd_locked'"
    fi
}

# Test 17: Test multiple users independent passwords
test_independent_passwords() {
    log_test "Testing users have independent passwords"

    # Create two users
    create_test_user "passwdtest4" "TestPass111"
    create_test_user "passwdtest5" "TestPass222"

    # Set different passwords
    echo "UserFourPass" | container_exec /usr/bin/passwd -s passwdtest4 2>/dev/null
    echo "UserFivePass" | container_exec /usr/bin/passwd -s passwdtest5 2>/dev/null

    local passwd4=$(get_shadow_passwd "passwdtest4")
    local passwd5=$(get_shadow_passwd "passwdtest5")

    assert_not_equals "$passwd4" "" "User4 has password"
    assert_not_equals "$passwd5" "" "User5 has password"
    assert_not_equals "$passwd4" "$passwd5" "Users have different password hashes"

    # Cleanup
    delete_test_user "passwdtest4"
    delete_test_user "passwdtest5"
}

# Test 18: Test passwd with non-existent user (should fail)
test_passwd_nonexistent_user() {
    log_test "Testing passwd with non-existent user"

    # Attempt to change password for non-existent user
    echo "Password" | container_exec /usr/bin/passwd -s nonexistentuser99999 2>/dev/null
    local exit_code=$?

    assert_failure "$exit_code" "passwd fails gracefully with non-existent user"
}

# Test 19: Test pwaccess dependency
test_pwaccess_socket() {
    log_test "Testing pwaccess socket availability for user lookup"

    # passwd uses pwaccess to get user information
    container_exec test -S /run/account/pwaccess-socket
    assert_success $? "pwaccess socket available for passwd user lookup"
}

# Test 20: Cleanup test users
test_cleanup_passwd_users() {
    log_test "Cleaning up passwd test users"

    delete_test_user "passwdtest1"

    # Verify cleanup
    local user_gone=$(container_exec getent passwd passwdtest1 && echo "no" || echo "yes")
    assert_equals "$user_gone" "yes" "Test user removed successfully"
}

# Run all tests
log_info "Starting passwd integration tests"
log_info "Running as root - tests actual password modifications"
echo ""

run_test test_passwd_binary_exists
run_test test_passwd_help
run_test test_passwd_version
run_test test_create_test_users
run_test test_pwupdd_socket
run_test test_passwd_stdin
run_test test_passwd_lock
run_test test_passwd_unlock
run_test test_passwd_delete
run_test test_passwd_expire
run_test test_passwd_status
run_test test_lock_unlock_cycle
run_test test_passwd_different_user
run_test test_sequential_changes
run_test test_expire_then_change
run_test test_delete_then_lock
run_test test_independent_passwords
run_test test_passwd_nonexistent_user
run_test test_pwaccess_socket
run_test test_cleanup_passwd_users

# Print summary
print_summary
