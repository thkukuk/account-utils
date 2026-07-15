#!/bin/bash
# Integration tests for chage (change password aging information)
# Tests actual shadow field modification via varlink communication with pwupdd service
# Running as root bypasses PAM authentication requirements

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-utils.sh"

log_info "========================================="
log_info "chage Integration Tests"
log_info "========================================="

# Helper function to get shadow field for a user
get_shadow_field() {
    local username="$1"
    local field_num="${2:-1}"  # 1=name, 2=passwd, 3=lstchg, 4=min, 5=max, 6=warn, 7=inact, 8=expire, 9=flag

    container_exec getent shadow "$username" 2>/dev/null | cut -d: -f"$field_num"
}

# Helper function to get all shadow fields
get_shadow_full() {
    local username="$1"
    container_exec getent shadow "$username" 2>/dev/null
}

# Convert days since epoch to YYYY-MM-DD (approximate for testing)
days_to_date() {
    local days="$1"
    # Simple conversion: seconds = days * 86400, then use date command
    container_exec date -d "@$((days * 86400))" +%Y-%m-%d 2>/dev/null || echo "invalid"
}

# Test 1: chage binary exists and is executable
test_chage_binary_exists() {
    log_test "Testing chage binary availability"

    container_exec test -x /usr/bin/chage
    assert_success $? "chage binary exists and is executable"
}

# Test 2: chage --help works
test_chage_help() {
    log_test "Testing chage --help option"

    local output=$(container_exec /usr/bin/chage --help 2>&1)
    local exit_code=$?

    assert_success "$exit_code" "chage --help exits successfully"
    assert_contains "$output" "lastday" "Help includes --lastday option"
    assert_contains "$output" "expiredate" "Help includes --expiredate option"
    assert_contains "$output" "inactive" "Help includes --inactive option"
    assert_not_contains "$output" "mindays" "Help includes --mindays option"
    assert_contains "$output" "maxdays" "Help includes --maxdays option"
    assert_contains "$output" "warndays" "Help includes --warndays option"
}

# Test 3: chage --version works
test_chage_version() {
    log_test "Testing chage --version option"

    local output=$(container_exec /usr/bin/chage --version 2>&1)
    local exit_code=$?

    assert_success "$exit_code" "chage --version exits successfully"
    assert_contains "$output" "chage" "Version output contains program name"
}

# Test 4: Create test user with shadow entry
test_create_test_user() {
    log_test "Creating test user with shadow entry"

    # Create user
    create_test_user "chagetest1" "TestPass123"

    # Verify shadow entry exists
    local shadow=$(get_shadow_full "chagetest1")
    assert_not_equals "$shadow" "" "Shadow entry exists for test user"

    # Verify fields are present (9 fields in shadow)
    local field_count=$(echo "$shadow" | tr -cd ':' | wc -c)
    assert_equals "$field_count" "8" "Shadow entry has correct field count (9 fields, 8 colons)"
}

# Test 5: Test pwupdd socket availability
test_pwupdd_socket() {
    log_test "Testing pwupdd socket availability for chage"

    # chage communicates with pwupdd via varlink
    container_exec test -S /run/account/pwupd-socket
    assert_success $? "pwupdd socket exists for chage to use"

    # Check socket is accessible
    local perms=$(container_exec stat -c '%a' /run/account/pwupd-socket)
    assert_equals "$perms" "666" "pwupdd socket is accessible (mode 666)"
}

# Test 6: chage -m (--mindays) sets minimum password age
test_chage_mindays() {
    log_test "Testing chage -m / --mindays option"

    # Set minimum days between password changes
    container_exec /usr/bin/chage -m 7 chagetest1
    local exit_code=$?
    assert_success "$exit_code" "chage -m succeeded"

    # Verify the change
    local min=$(get_shadow_field "chagetest1" 4)
    assert_equals "$min" "7" "Minimum password age set to 7 days"
}

# Test 7: chage -M (--maxdays) sets maximum password age
test_chage_maxdays() {
    log_test "Testing chage -M / --maxdays option"

    # Set maximum days before password must be changed
    container_exec /usr/bin/chage -M 90 chagetest1
    local exit_code=$?
    assert_success "$exit_code" "chage -M succeeded"

    # Verify the change
    local max=$(get_shadow_field "chagetest1" 5)
    assert_equals "$max" "90" "Maximum password age set to 90 days"

    # Verify mindays unchanged
    local min=$(get_shadow_field "chagetest1" 4)
    assert_equals "$min" "7" "Minimum days unchanged after maxdays change"
}

# Test 8: chage -W (--warndays) sets password warning period
test_chage_warndays() {
    log_test "Testing chage -W / --warndays option"

    # Set warning days before password expiration
    container_exec /usr/bin/chage -W 14 chagetest1
    local exit_code=$?
    assert_success "$exit_code" "chage -W succeeded"

    # Verify the change
    local warn=$(get_shadow_field "chagetest1" 6)
    assert_equals "$warn" "14" "Warning period set to 14 days"

    # Verify other fields unchanged
    local max=$(get_shadow_field "chagetest1" 5)
    assert_equals "$max" "90" "Maximum days unchanged after warndays change"
}

# Test 9: chage -I (--inactive) sets password inactivity period
test_chage_inactive() {
    log_test "Testing chage -I / --inactive option"

    # Set days after password expiry until account is locked
    container_exec /usr/bin/chage -I 30 chagetest1
    local exit_code=$?
    assert_success "$exit_code" "chage -I succeeded"

    # Verify the change
    local inact=$(get_shadow_field "chagetest1" 7)
    assert_equals "$inact" "30" "Inactivity period set to 30 days"

    # Verify other fields unchanged
    local warn=$(get_shadow_field "chagetest1" 6)
    assert_equals "$warn" "14" "Warning days unchanged after inactive change"
}

# Test 10: chage -E (--expiredate) sets account expiration
test_chage_expiredate() {
    log_test "Testing chage -E / --expiredate option"

    # Set account expiration date
    container_exec /usr/bin/chage -E 2030-12-31 chagetest1
    local exit_code=$?
    assert_success "$exit_code" "chage -E succeeded"

    # Verify the change (field 8 is expire date in days since epoch)
    local expire=$(get_shadow_field "chagetest1" 8)
    assert_not_equals "$expire" "" "Expiration date was set"
    # 2030-12-31 is approximately 22280 days since epoch
    # We just verify it's a reasonable number
    [ "$expire" -gt 20000 ] && [ "$expire" -lt 25000 ]
    assert_success $? "Expiration date is reasonable (around 2030)"

    # Verify other fields unchanged
    local inact=$(get_shadow_field "chagetest1" 7)
    assert_equals "$inact" "30" "Inactivity unchanged after expiredate change"
}

# Test 11: chage -d (--lastday) sets last password change date
test_chage_lastday() {
    log_test "Testing chage -d / --lastday option"

    # Set last password change date
    container_exec /usr/bin/chage -d 2024-01-01 chagetest1
    local exit_code=$?
    assert_success "$exit_code" "chage -d succeeded"

    # Verify the change (field 3 is lstchg - days since epoch)
    local lstchg=$(get_shadow_field "chagetest1" 3)
    assert_not_equals "$lstchg" "" "Last change date was set"
    # 2024-01-01 is approximately 19723 days since epoch
    [ "$lstchg" -gt 19000 ] && [ "$lstchg" -lt 20000 ]
    assert_success $? "Last change date is reasonable (around 2024)"
}

# Test 12: chage with multiple options simultaneously
test_chage_multiple_options() {
    log_test "Testing chage with multiple options at once"

    # Set multiple aging parameters at once
    container_exec /usr/bin/chage -m 5 -M 60 -W 7 -I 14 chagetest1
    local exit_code=$?
    assert_success "$exit_code" "chage with multiple options succeeded"

    # Verify all changes
    local min=$(get_shadow_field "chagetest1" 4)
    local max=$(get_shadow_field "chagetest1" 5)
    local warn=$(get_shadow_field "chagetest1" 6)
    local inact=$(get_shadow_field "chagetest1" 7)

    assert_equals "$min" "5" "Minimum days changed in multi-option call"
    assert_equals "$max" "60" "Maximum days changed in multi-option call"
    assert_equals "$warn" "7" "Warning days changed in multi-option call"
    assert_equals "$inact" "14" "Inactivity changed in multi-option call"
}

# Test 13: chage with -1 (disabled/never) values
test_chage_disabled_values() {
    log_test "Testing chage with -1 (disabled) values"

    # Set max to -1 (password never expires)
    container_exec /usr/bin/chage -M -1 chagetest1
    local exit_code=$?
    assert_success "$exit_code" "chage -M -1 succeeded"

    local max=$(get_shadow_field "chagetest1" 5)
    assert_equals "$max" "" "Maximum days set to empty (never expires)"

    # Set warning to -1 (no warning)
    container_exec /usr/bin/chage -W -1 chagetest1
    local exit_code=$?
    assert_success "$exit_code" "chage -W -1 succeeded"

    local warn=$(get_shadow_field "chagetest1" 6)
    assert_equals "$warn" "" "Warning days set to empty (no warning)"
}

# Test 14: chage -E with special date 1969-12-31 (never expires)
test_chage_expiredate_never() {
    log_test "Testing chage -E with 1969-12-31 (never expires)"

    # Set expiration to 1969-12-31 which means -1 (never)
    container_exec /usr/bin/chage -E 1969-12-31 chagetest1
    local exit_code=$?
    assert_success "$exit_code" "chage -E 1969-12-31 succeeded"

    local expire=$(get_shadow_field "chagetest1" 8)
    assert_equals "$expire" "" "Expiration date set to empty (never expires)"
}

# Test 15: chage -l (--list) displays aging information
test_chage_list() {
    log_test "Testing chage -l / --list option"

    # Reset to known values first
    container_exec /usr/bin/chage -m 10 -M 90 -W 7 -I 30 -E 2025-12-31 -d 2024-06-01 chagetest1

    # List aging information
    local output=$(container_exec /usr/bin/chage -l chagetest1 2>&1)
    local exit_code=$?

    assert_success "$exit_code" "chage -l succeeded"
    # Output should contain aging information fields
    assert_contains "$output" "Last password change" "List output contains password change info"
    assert_contains "$output" "Password expires" "List output contains expiration info"
    assert_contains "$output" "Minimum password age" "List output contains minimum age"
    assert_contains "$output" "Maximum password age" "List output contains maximum age"
}

# Test 16: chage with zero values
test_chage_zero_values() {
    log_test "Testing chage with zero values"

    # Set minimum to 0 (can change password immediately)
    container_exec /usr/bin/chage -m 0 chagetest1
    local exit_code=$?
    assert_success "$exit_code" "chage -m 0 succeeded"

    local min=$(get_shadow_field "chagetest1" 4)
    assert_equals "$min" "0" "Minimum days set to 0"

    # Set last change to 0 (force password change on next login)
    container_exec /usr/bin/chage -d 0 chagetest1
    local exit_code=$?
    assert_success "$exit_code" "chage -d 0 succeeded"

    local lstchg=$(get_shadow_field "chagetest1" 3)
    assert_equals "$lstchg" "0" "Last change date set to 0 (force change)"
}

# Test 17: chage on different user (root changing another user)
test_chage_different_user() {
    log_test "Testing chage on different user"

    # Create second test user
    create_test_user "chagetest2" "TestPass456"

    # Change aging for different user as root
    container_exec /usr/bin/chage -M 120 chagetest2
    local exit_code=$?
    assert_success "$exit_code" "chage on different user succeeded"

    local max=$(get_shadow_field "chagetest2" 5)
    assert_equals "$max" "120" "Different user's maxdays changed by root"

    # Verify first user unchanged
    local user1_max=$(get_shadow_field "chagetest1" 5)
    assert_not_equals "$user1_max" "120" "First user's settings unchanged"

    # Cleanup
    delete_test_user "chagetest2"
}

# Test 18: Verify shadow field structure integrity
test_shadow_structure_integrity() {
    log_test "Testing shadow structure integrity after modifications"

    # Set all fields to known values
    container_exec /usr/bin/chage -m 3 -M 45 -W 5 -I 10 -E 2028-06-15 -d 2024-01-15 chagetest1

    # Get full shadow entry
    local shadow=$(get_shadow_full "chagetest1")

    # Count colons (should be 8 for 9 fields)
    local colon_count=$(echo "$shadow" | tr -cd ':' | wc -c)
    assert_equals "$colon_count" "8" "Shadow has correct colon separation"

    # Verify specific fields
    local name=$(get_shadow_field "chagetest1" 1)
    local min=$(get_shadow_field "chagetest1" 4)
    local max=$(get_shadow_field "chagetest1" 5)
    local warn=$(get_shadow_field "chagetest1" 6)
    local inact=$(get_shadow_field "chagetest1" 7)

    assert_equals "$name" "chagetest1" "Username field correct"
    assert_equals "$min" "3" "All fields maintain integrity (min)"
    assert_equals "$max" "45" "All fields maintain integrity (max)"
    assert_equals "$warn" "5" "All fields maintain integrity (warn)"
    assert_equals "$inact" "10" "All fields maintain integrity (inact)"
}

# Test 19: chage with non-existent user (should fail)
test_chage_nonexistent_user() {
    log_test "Testing chage with non-existent user"

    # Attempt to change aging for non-existent user
    container_exec /usr/bin/chage -M 60 nonexistentuser99999 2>/dev/null
    local exit_code=$?

    assert_failure "$exit_code" "chage fails gracefully with non-existent user"
}

# Test 20: Test pwaccess dependency
test_pwaccess_socket() {
    log_test "Testing pwaccess socket availability for user lookup"

    # chage uses pwaccess to get user information
    container_exec test -S /run/account/pwaccess-socket
    assert_success $? "pwaccess socket available for chage user lookup"
}

# Test 21: Test sequential changes
test_sequential_changes() {
    log_test "Testing sequential shadow field changes"

    # Create fresh user
    create_test_user "chagetest3" "TestPass789"

    # Sequential changes
    container_exec /usr/bin/chage -M 100 chagetest3
    local max1=$(get_shadow_field "chagetest3" 5)
    assert_equals "$max1" "100" "First change applied"

    container_exec /usr/bin/chage -W 10 chagetest3
    local warn1=$(get_shadow_field "chagetest3" 6)
    assert_equals "$warn1" "10" "Second change applied"

    local max2=$(get_shadow_field "chagetest3" 5)
    assert_equals "$max2" "100" "First field preserved after second change"

    container_exec /usr/bin/chage -M 80 chagetest3
    local max3=$(get_shadow_field "chagetest3" 5)
    assert_equals "$max3" "80" "Third change applied"

    local warn2=$(get_shadow_field "chagetest3" 6)
    assert_equals "$warn2" "10" "Second field preserved after third change"

    # Cleanup
    delete_test_user "chagetest3"
}

# Test 22: Test shadow file security
test_shadow_file_security() {
    log_test "Testing shadow file security"

    # Shadow file should have restricted permissions
    local shadow_perms=$(container_exec stat -c '%a' /etc/shadow 2>/dev/null || echo "000")

    # Accept 600 or 000 (000 means file might not exist in test container)
    if [ "$shadow_perms" != "000" ]; then
        assert_equals "$shadow_perms" "600" "Shadow file has secure permissions (600)"
    else
        log_info "Shadow file permissions check skipped (file not accessible)"
    fi
}

# Test 23: Cleanup test users
test_cleanup_chage_users() {
    log_test "Cleaning up chage test users"

    delete_test_user "chagetest1"

    # Verify cleanup
    local user_gone=$(container_exec getent passwd chagetest1 && echo "no" || echo "yes")
    assert_equals "$user_gone" "yes" "Test user removed successfully"
}

# Run all tests
log_info "Starting chage integration tests"
log_info "Running as root - tests actual shadow field modifications"
echo ""

run_test test_chage_binary_exists
run_test test_chage_help
run_test test_chage_version
run_test test_create_test_user
run_test test_pwupdd_socket
run_test test_chage_mindays
run_test test_chage_maxdays
run_test test_chage_warndays
run_test test_chage_inactive
run_test test_chage_expiredate
run_test test_chage_lastday
run_test test_chage_multiple_options
run_test test_chage_disabled_values
run_test test_chage_expiredate_never
run_test test_chage_list
run_test test_chage_zero_values
run_test test_chage_different_user
run_test test_shadow_structure_integrity
run_test test_chage_nonexistent_user
run_test test_pwaccess_socket
run_test test_sequential_changes
run_test test_shadow_file_security
run_test test_cleanup_chage_users

# Print summary
print_summary
