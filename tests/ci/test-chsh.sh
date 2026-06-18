#!/bin/bash
# Integration tests for chsh (change login shell)
# Tests actual shell modification via varlink communication with pwupdd service
# Running as root bypasses PAM authentication requirements

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-utils.sh"

log_info "========================================="
log_info "chsh Integration Tests"
log_info "========================================="

# Helper function to get user's shell
get_user_shell() {
    local username="$1"
    container_exec getent passwd "$username" | cut -d: -f7
}

# Helper function to get passwd entry
get_passwd_entry() {
    local username="$1"
    container_exec getent passwd "$username"
}

# Test 1: chsh binary exists and is executable
test_chsh_binary_exists() {
    log_test "Testing chsh binary availability"

    container_exec test -x /usr/bin/chsh
    assert_success $? "chsh binary exists and is executable"
}

# Test 2: chsh --help works
test_chsh_help() {
    log_test "Testing chsh --help option"

    local output=$(container_exec /usr/bin/chsh --help 2>&1)
    local exit_code=$?

    assert_success "$exit_code" "chsh --help exits successfully"
    assert_contains "$output" "shell" "Help includes --shell option"
    assert_contains "$output" "list-shells" "Help includes --list-shells option"
}

# Test 3: chsh --version works
test_chsh_version() {
    log_test "Testing chsh --version option"

    local output=$(container_exec /usr/bin/chsh --version 2>&1)
    local exit_code=$?

    assert_success "$exit_code" "chsh --version exits successfully"
    assert_contains "$output" "chsh" "Version output contains program name"
}

# Test 4: Create test users with default shell
test_create_test_users() {
    log_test "Creating test users with default shell"

    # Create user
    create_test_user "chshtest1" "TestPass123"

    # Verify user has a shell
    local shell=$(get_user_shell "chshtest1")
    assert_not_equals "$shell" "" "Test user has a shell assigned"
    log_info "Default shell: $shell"
}

# Test 5: Test pwupdd socket availability
test_pwupdd_socket() {
    log_test "Testing pwupdd socket availability for chsh"

    # chsh communicates with pwupdd via varlink
    container_exec test -S /run/account/pwupd-socket
    assert_success $? "pwupdd socket exists for chsh to use"

    # Check socket is accessible
    local perms=$(container_exec stat -c '%a' /run/account/pwupd-socket)
    assert_equals "$perms" "666" "pwupdd socket is accessible (mode 666)"
}

# Test 6: chsh -s (--shell) changes user shell
test_chsh_change_shell() {
    log_test "Testing chsh -s / --shell option"

    # Get current shell
    local shell_before=$(get_user_shell "chshtest1")
    log_info "Shell before: $shell_before"

    # Determine which shell to switch to
    local new_shell="/bin/sh"
    if [ "$shell_before" = "/bin/sh" ]; then
        new_shell="/bin/bash"
    fi

    # Verify new shell exists
    if ! container_exec test -f "$new_shell" 2>/dev/null; then
        log_info "Shell $new_shell not available, using /bin/sh"
        new_shell="/bin/sh"
    fi

    # Change shell as root (no PAM authentication required)
    container_exec /usr/bin/chsh -s "$new_shell" chshtest1
    local exit_code=$?
    assert_success "$exit_code" "chsh -s succeeded"

    # Verify the change
    local shell_after=$(get_user_shell "chshtest1")
    assert_equals "$shell_after" "$new_shell" "Shell was changed successfully"
}

# Test 7: chsh changes only shell field, not other fields
test_chsh_preserves_other_fields() {
    log_test "Testing chsh preserves other passwd fields"

    # Get current passwd entry
    local passwd_before=$(get_passwd_entry "chshtest1")
    local name_before=$(echo "$passwd_before" | cut -d: -f1)
    local uid_before=$(echo "$passwd_before" | cut -d: -f3)
    local gid_before=$(echo "$passwd_before" | cut -d: -f4)
    local gecos_before=$(echo "$passwd_before" | cut -d: -f5)
    local home_before=$(echo "$passwd_before" | cut -d: -f6)
    local shell_before=$(echo "$passwd_before" | cut -d: -f7)

    # Change shell back
    local target_shell="/bin/bash"
    if [ "$shell_before" = "/bin/bash" ]; then
        target_shell="/bin/sh"
    fi

    container_exec /usr/bin/chsh -s "$target_shell" chshtest1

    # Get passwd entry after change
    local passwd_after=$(get_passwd_entry "chshtest1")
    local name_after=$(echo "$passwd_after" | cut -d: -f1)
    local uid_after=$(echo "$passwd_after" | cut -d: -f3)
    local gid_after=$(echo "$passwd_after" | cut -d: -f4)
    local gecos_after=$(echo "$passwd_after" | cut -d: -f5)
    local home_after=$(echo "$passwd_after" | cut -d: -f6)
    local shell_after=$(echo "$passwd_after" | cut -d: -f7)

    # Verify other fields unchanged
    assert_equals "$name_after" "$name_before" "Username unchanged"
    assert_equals "$uid_after" "$uid_before" "UID unchanged"
    assert_equals "$gid_after" "$gid_before" "GID unchanged"
    assert_equals "$gecos_after" "$gecos_before" "GECOS unchanged"
    assert_equals "$home_after" "$home_before" "Home directory unchanged"

    # Verify shell changed
    assert_not_equals "$shell_after" "$shell_before" "Shell was changed"
    assert_equals "$shell_after" "$target_shell" "Shell changed to target"
}

# Test 8: chsh with absolute path for shell
test_chsh_absolute_path() {
    log_test "Testing chsh with absolute path"

    # Change to shell with absolute path
    container_exec /usr/bin/chsh -s /bin/sh chshtest1
    local exit_code=$?
    assert_success "$exit_code" "chsh with absolute path succeeded"

    local shell=$(get_user_shell "chshtest1")
    assert_equals "$shell" "/bin/sh" "Absolute path shell set correctly"
}

# Test 9: chsh on different user (root changing another user)
test_chsh_different_user() {
    log_test "Testing chsh on different user"

    # Create second test user
    create_test_user "chshtest2" "TestPass456"

    local shell_before=$(get_user_shell "chshtest2")
    log_info "User2 shell before: $shell_before"

    # Change shell for different user as root
    container_exec /usr/bin/chsh -s /bin/sh chshtest2
    local exit_code=$?
    assert_success "$exit_code" "chsh on different user succeeded"

    local shell_after=$(get_user_shell "chshtest2")
    assert_equals "$shell_after" "/bin/sh" "Different user's shell changed by root"

    # Verify first user unchanged
    local user1_shell=$(get_user_shell "chshtest1")
    assert_equals "$user1_shell" "/bin/sh" "First user's shell unchanged"

    # Cleanup
    delete_test_user "chshtest2"
}

# Test 10: chsh -l (--list-shells) displays available shells
test_chsh_list_shells() {
    log_test "Testing chsh -l / --list-shells option"

    # List available shells
    local output=$(container_exec /usr/bin/chsh -l 2>&1)
    local exit_code=$?

    assert_success "$exit_code" "chsh -l succeeded"
    # Output should contain at least some shell path or configuration info
    log_info "Available shells output: ${output:0:100}..."
    # Just verify command executed successfully
}

# Test 11: chsh with valid shell path
test_chsh_valid_shell() {
    log_test "Testing chsh with valid shell path"

    # Find a valid shell in the container
    local valid_shell=""
    for shell in /bin/bash /bin/sh /usr/bin/bash /bin/dash; do
        if container_exec test -x "$shell" 2>/dev/null; then
            valid_shell="$shell"
            break
        fi
    done

    if [ -z "$valid_shell" ]; then
        valid_shell="/bin/sh"  # Fallback
    fi

    log_info "Testing with valid shell: $valid_shell"

    container_exec /usr/bin/chsh -s "$valid_shell" chshtest1
    local exit_code=$?
    assert_success "$exit_code" "chsh with valid shell succeeded"

    local shell=$(get_user_shell "chshtest1")
    assert_equals "$shell" "$valid_shell" "Valid shell set correctly"
}

# Test 12: Test passwd field structure integrity
test_passwd_structure_integrity() {
    log_test "Testing passwd structure integrity after shell change"

    # Change shell
    container_exec /usr/bin/chsh -s /bin/bash chshtest1

    # Get passwd entry
    local passwd=$(get_passwd_entry "chshtest1")

    # Verify field count (7 fields = 6 colons)
    local colon_count=$(echo "$passwd" | tr -cd ':' | wc -c)
    assert_equals "$colon_count" "6" "Passwd has correct field count (7 fields, 6 colons)"

    # Verify all fields are present
    local name=$(echo "$passwd" | cut -d: -f1)
    local uid=$(echo "$passwd" | cut -d: -f3)
    local gid=$(echo "$passwd" | cut -d: -f4)
    local home=$(echo "$passwd" | cut -d: -f6)
    local shell=$(echo "$passwd" | cut -d: -f7)

    assert_equals "$name" "chshtest1" "Name field correct"
    assert_not_equals "$uid" "" "UID field present"
    assert_not_equals "$gid" "" "GID field present"
    assert_not_equals "$home" "" "Home field present"
    assert_not_equals "$shell" "" "Shell field present"
}

# Test 13: Test sequential shell changes
test_sequential_changes() {
    log_test "Testing sequential shell changes"

    # Create fresh user
    create_test_user "chshtest3" "TestPass789"

    # First change
    container_exec /usr/bin/chsh -s /bin/sh chshtest3
    local shell1=$(get_user_shell "chshtest3")
    assert_equals "$shell1" "/bin/sh" "First shell change applied"

    # Second change
    container_exec /usr/bin/chsh -s /bin/bash chshtest3
    local shell2=$(get_user_shell "chshtest3")
    assert_equals "$shell2" "/bin/bash" "Second shell change applied"

    # Third change
    container_exec /usr/bin/chsh -s /bin/sh chshtest3
    local shell3=$(get_user_shell "chshtest3")
    assert_equals "$shell3" "/bin/sh" "Third shell change applied"

    # Cleanup
    delete_test_user "chshtest3"
}

# Test 14: Test shell is absolute path
test_shell_absolute_path() {
    log_test "Testing shell field contains absolute path"

    local shell=$(get_user_shell "chshtest1")

    # Shell should start with /
    if [[ "$shell" == /* ]]; then
        assert_success 0 "Shell is an absolute path"
    else
        log_warn "Shell is not absolute: $shell"
        assert_success 1 "Shell should be absolute path"
    fi
}

# Test 15: Test multiple users have independent shells
test_independent_shells() {
    log_test "Testing users have independent shell settings"

    # Create two users
    create_test_user "chshtest4" "TestPass111"
    create_test_user "chshtest5" "TestPass222"

    # Set different shells
    container_exec /usr/bin/chsh -s /bin/sh chshtest4
    container_exec /usr/bin/chsh -s /bin/bash chshtest5

    local shell4=$(get_user_shell "chshtest4")
    local shell5=$(get_user_shell "chshtest5")

    assert_equals "$shell4" "/bin/sh" "User4 has correct shell"
    assert_equals "$shell5" "/bin/bash" "User5 has correct shell"
    assert_not_equals "$shell4" "$shell5" "Users have different shells"

    # Cleanup
    delete_test_user "chshtest4"
    delete_test_user "chshtest5"
}

# Test 16: Test common shell paths exist
test_common_shells_exist() {
    log_test "Testing common shell paths"

    # At least /bin/sh should exist (POSIX requirement)
    container_exec test -f /bin/sh
    assert_success $? "/bin/sh exists"

    # Check for bash
    if container_exec test -f /bin/bash 2>/dev/null; then
        log_info "/bin/bash exists"
    elif container_exec test -f /usr/bin/bash 2>/dev/null; then
        log_info "/usr/bin/bash exists"
    else
        log_info "bash not found in common locations"
    fi
}

# Test 17: Test chsh with non-existent user (should fail)
test_chsh_nonexistent_user() {
    log_test "Testing chsh with non-existent user"

    # Attempt to change shell for non-existent user
    local output
    output=$(container_exec /usr/bin/chsh -s /bin/sh nonexistentuser99999 2>&1)
    local exit_code=$?

    assert_failure "$exit_code" "chsh fails gracefully with non-existent user"
    assert_equals "$exit_code" "61" "chsh returns ENODATA (61) for non-existent user"
    assert_contains "$output" "user 'nonexistentuser99999' does not exist" "Error message indicates user does not exist"
}

# Test 18: Test pwaccess dependency
test_pwaccess_socket() {
    log_test "Testing pwaccess socket availability for user lookup"

    # chsh uses pwaccess to get user information
    container_exec test -S /run/account/pwaccess-socket
    assert_success $? "pwaccess socket available for chsh user lookup"
}

# Test 19: Test root user has shell
test_root_shell() {
    log_test "Testing root user has shell"

    local root_shell=$(get_user_shell "root")

    assert_not_equals "$root_shell" "" "Root user has a shell"
    log_info "Root shell: $root_shell"

    # Root shell should be absolute path
    if [[ "$root_shell" == /* ]]; then
        assert_success 0 "Root shell is absolute path"
    else
        log_warn "Root shell not absolute: $root_shell"
    fi
}

# Test 20: Cleanup test users
test_cleanup_chsh_users() {
    log_test "Cleaning up chsh test users"

    delete_test_user "chshtest1"

    # Verify cleanup
    local user_gone=$(container_exec getent passwd chshtest1 && echo "no" || echo "yes")
    assert_equals "$user_gone" "yes" "Test user removed successfully"
}

# Run all tests
log_info "Starting chsh integration tests"
log_info "Running as root - tests actual shell modifications"
echo ""

run_test test_chsh_binary_exists
run_test test_chsh_help
run_test test_chsh_version
run_test test_create_test_users
run_test test_pwupdd_socket
run_test test_chsh_change_shell
run_test test_chsh_preserves_other_fields
run_test test_chsh_absolute_path
run_test test_chsh_different_user
run_test test_chsh_list_shells
run_test test_chsh_valid_shell
run_test test_passwd_structure_integrity
run_test test_sequential_changes
run_test test_shell_absolute_path
run_test test_independent_shells
run_test test_common_shells_exist
run_test test_chsh_nonexistent_user
run_test test_pwaccess_socket
run_test test_root_shell
run_test test_cleanup_chsh_users

# Print summary
print_summary
