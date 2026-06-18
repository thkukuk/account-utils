#!/bin/bash
# Integration tests for chfn (change GECOS/finger information)
# Tests actual GECOS field modification via varlink communication with pwupdd service
# Running as root bypasses PAM authentication requirements

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-utils.sh"

log_info "========================================="
log_info "chfn Integration Tests"
log_info "========================================="

# Helper function to get GECOS field for a user
get_gecos_field() {
    local username="$1"
    local field_num="${2:-1}"  # 1=full_name, 2=room, 3=work_phone, 4=home_phone, 5=other

    local gecos=$(container_exec getent passwd "$username" | cut -d: -f5)

    # Special handling for field 5 (other) - it's the last field and can contain commas
    if [ "$field_num" = "5" ]; then
        # Get everything after the 4th comma (the "other" field is everything remaining)
        echo "$gecos" | cut -d, -f5-
    else
        # For fields 1-4, extract the specific field
        echo "$gecos" | cut -d, -f"$field_num"
    fi
}

# Helper function to get full GECOS
get_gecos_full() {
    local username="$1"
    container_exec getent passwd "$username" | cut -d: -f5
}

# Test 1: chfn binary exists and is executable
test_chfn_binary_exists() {
    log_test "Testing chfn binary availability"

    container_exec test -x /usr/bin/chfn
    assert_success $? "chfn binary exists and is executable"
}

# Test 2: chfn --help works
test_chfn_help() {
    log_test "Testing chfn --help option"

    local output=$(container_exec /usr/bin/chfn --help 2>&1)
    local exit_code=$?

    assert_success "$exit_code" "chfn --help exits successfully"
    assert_contains "$output" "full-name" "Help includes --full-name option"
    assert_contains "$output" "home-phone" "Help includes --home-phone option"
    assert_contains "$output" "work-phone" "Help includes --work-phone option"
    assert_contains "$output" "room" "Help includes --room option"
    assert_contains "$output" "other" "Help includes --other option"
}

# Test 3: chfn --version works
test_chfn_version() {
    log_test "Testing chfn --version option"

    local output=$(container_exec /usr/bin/chfn --version 2>&1)
    local exit_code=$?

    assert_success "$exit_code" "chfn --version exits successfully"
    assert_contains "$output" "chfn" "Version output contains program name"
}

# Test 4: Create test users for GECOS modification tests
test_create_test_users() {
    log_test "Creating test users for chfn tests"

    # Create primary test user
    create_test_user "chfntest1" "TestPass123"

    # Set initial GECOS: Full Name,Room,Work Phone,Home Phone,Other
    container_exec usermod -c "John Doe,101,555-1234,555-5678,Building A" chfntest1

    # Verify GECOS was set
    local gecos=$(get_gecos_full "chfntest1")
    assert_contains "$gecos" "John Doe" "Initial GECOS contains full name"

    local full_name=$(get_gecos_field "chfntest1" 1)
    assert_equals "$full_name" "John Doe" "Full name field is correct"
}

# Test 5: Test pwupdd socket availability
test_pwupdd_socket() {
    log_test "Testing pwupdd socket availability for chfn"

    # chfn communicates with pwupdd via varlink
    container_exec test -S /run/account/pwupd-socket
    assert_success $? "pwupdd socket exists for chfn to use"

    # Check socket is accessible
    local perms=$(container_exec stat -c '%a' /run/account/pwupd-socket)
    assert_equals "$perms" "666" "pwupdd socket is accessible (mode 666)"
}

# Test 6: chfn -f (--full-name) changes full name
test_chfn_full_name() {
    log_test "Testing chfn -f / --full-name option"

    # Change full name as root (no PAM authentication required)
    container_exec /usr/bin/chfn -f "Jane Smith" chfntest1
    local exit_code=$?
    assert_success "$exit_code" "chfn -f succeeded"

    # Verify the change
    local new_name=$(get_gecos_field "chfntest1" 1)
    assert_equals "$new_name" "Jane Smith" "Full name was changed successfully"

    # Verify other fields remain unchanged
    local room=$(get_gecos_field "chfntest1" 2)
    assert_equals "$room" "101" "Room field unchanged after full name change"
}

# Test 7: chfn -r (--room) changes room number
test_chfn_room() {
    log_test "Testing chfn -r / --room option"

    # Change room number
    container_exec /usr/bin/chfn -r "202" chfntest1
    local exit_code=$?
    assert_success "$exit_code" "chfn -r succeeded"

    # Verify the change
    local new_room=$(get_gecos_field "chfntest1" 2)
    assert_equals "$new_room" "202" "Room number was changed successfully"

    # Verify full name remains unchanged
    local name=$(get_gecos_field "chfntest1" 1)
    assert_equals "$name" "Jane Smith" "Full name unchanged after room change"
}

# Test 8: chfn -w (--work-phone) changes work phone
test_chfn_work_phone() {
    log_test "Testing chfn -w / --work-phone option"

    # Change work phone
    container_exec /usr/bin/chfn -w "555-9999" chfntest1
    local exit_code=$?
    assert_success "$exit_code" "chfn -w succeeded"

    # Verify the change
    local new_work_phone=$(get_gecos_field "chfntest1" 3)
    assert_equals "$new_work_phone" "555-9999" "Work phone was changed successfully"

    # Verify other fields remain unchanged
    local room=$(get_gecos_field "chfntest1" 2)
    assert_equals "$room" "202" "Room field unchanged after work phone change"
}

# Test 9: chfn -h (--home-phone) changes home phone
test_chfn_home_phone() {
    log_test "Testing chfn -h / --home-phone option"

    # Change home phone
    container_exec /usr/bin/chfn -h "555-8888" chfntest1
    local exit_code=$?
    assert_success "$exit_code" "chfn -h succeeded"

    # Verify the change
    local new_home_phone=$(get_gecos_field "chfntest1" 4)
    assert_equals "$new_home_phone" "555-8888" "Home phone was changed successfully"

    # Verify other fields remain unchanged
    local work_phone=$(get_gecos_field "chfntest1" 3)
    assert_equals "$work_phone" "555-9999" "Work phone unchanged after home phone change"
}

# Test 10: chfn -o (--other) changes other information
test_chfn_other() {
    log_test "Testing chfn -o / --other option"

    # Change other information
    container_exec /usr/bin/chfn -o "Building C" chfntest1
    local exit_code=$?
    assert_success "$exit_code" "chfn -o succeeded"

    # Verify the change
    local new_other=$(get_gecos_field "chfntest1" 5)
    assert_equals "$new_other" "Building C" "Other information was changed successfully"

    # Verify other fields remain unchanged
    local home_phone=$(get_gecos_field "chfntest1" 4)
    assert_equals "$home_phone" "555-8888" "Home phone unchanged after other info change"
}

# Test 11: chfn with multiple options simultaneously
test_chfn_multiple_options() {
    log_test "Testing chfn with multiple options at once"

    # Change multiple fields at once
    container_exec /usr/bin/chfn -f "Bob Johnson" -r "303" -w "555-1111" -h "555-2222" -o "Dept HR" chfntest1
    local exit_code=$?
    assert_success "$exit_code" "chfn with multiple options succeeded"

    # Verify all changes
    local full_name=$(get_gecos_field "chfntest1" 1)
    local room=$(get_gecos_field "chfntest1" 2)
    local work_phone=$(get_gecos_field "chfntest1" 3)
    local home_phone=$(get_gecos_field "chfntest1" 4)
    local other=$(get_gecos_field "chfntest1" 5)

    assert_equals "$full_name" "Bob Johnson" "Full name changed in multi-option call"
    assert_equals "$room" "303" "Room changed in multi-option call"
    assert_equals "$work_phone" "555-1111" "Work phone changed in multi-option call"
    assert_equals "$home_phone" "555-2222" "Home phone changed in multi-option call"
    assert_equals "$other" "Dept HR" "Other info changed in multi-option call"
}

# Test 12: chfn with empty strings to clear fields
test_chfn_clear_fields() {
    log_test "Testing chfn with empty strings to clear fields"

    # Clear specific fields
    container_exec /usr/bin/chfn -r "" -o "" chfntest1
    local exit_code=$?
    assert_success "$exit_code" "chfn with empty strings succeeded"

    # Verify fields were cleared
    local room=$(get_gecos_field "chfntest1" 2)
    local other=$(get_gecos_field "chfntest1" 5)

    assert_equals "$room" "" "Room field cleared"
    assert_equals "$other" "" "Other field cleared"

    # Verify other fields remain
    local full_name=$(get_gecos_field "chfntest1" 1)
    assert_equals "$full_name" "Bob Johnson" "Full name unchanged when clearing other fields"
}

# Test 13: chfn with special characters in full name
test_chfn_special_chars_name() {
    log_test "Testing chfn with special characters in name"

    # Test with hyphen, apostrophe, period
    container_exec /usr/bin/chfn -f "Mary-Ann O'Connor Jr." chfntest1
    local exit_code=$?
    assert_success "$exit_code" "chfn with special characters succeeded"

    local full_name=$(get_gecos_field "chfntest1" 1)
    assert_equals "$full_name" "Mary-Ann O'Connor Jr." "Special characters preserved in name"
}

# Test 14: chfn with spaces in fields
test_chfn_spaces_in_fields() {
    log_test "Testing chfn with spaces in fields"

    # Test spaces in various fields
    container_exec /usr/bin/chfn -r "Suite 3-B" -o "Building A, Floor 2" chfntest1
    local exit_code=$?
    assert_success "$exit_code" "chfn with spaces succeeded"

    local room=$(get_gecos_field "chfntest1" 2)
    local other=$(get_gecos_field "chfntest1" 5)

    assert_equals "$room" "Suite 3-B" "Spaces preserved in room field"
    assert_equals "$other" "Building A, Floor 2" "Spaces and comma preserved in other field"
}

# Test 15: chfn on user with initially empty GECOS
test_chfn_empty_gecos_initial() {
    log_test "Testing chfn on user with empty GECOS"

    # Create user with empty GECOS
    create_test_user "chfntest2" "TestPass456"

    # Set full name on empty GECOS
    container_exec /usr/bin/chfn -f "Alice Williams" chfntest2
    local exit_code=$?
    assert_success "$exit_code" "chfn on empty GECOS succeeded"

    local full_name=$(get_gecos_field "chfntest2" 1)
    assert_equals "$full_name" "Alice Williams" "Full name set on previously empty GECOS"

    # Cleanup
    delete_test_user "chfntest2"
}

# Test 16: chfn with long field values
test_chfn_long_values() {
    log_test "Testing chfn with long field values"

    # Test with long full name
    local long_name="Alexander Maximilian Christopher Wellington III"
    container_exec /usr/bin/chfn -f "$long_name" chfntest1
    local exit_code=$?
    assert_success "$exit_code" "chfn with long name succeeded"

    local retrieved_name=$(get_gecos_field "chfntest1" 1)
    # Note: may be truncated by system limits, but should succeed
    assert_contains "$retrieved_name" "Alexander" "Long name was stored (at least partially)"
}

# Test 17: chfn with phone number formats
test_chfn_phone_formats() {
    log_test "Testing chfn with various phone number formats"

    # Test different phone formats
    container_exec /usr/bin/chfn -w "555-1234" -h "(555) 567-8901" chfntest1
    local exit_code=$?
    assert_success "$exit_code" "chfn with formatted phone numbers succeeded"

    local work_phone=$(get_gecos_field "chfntest1" 3)
    local home_phone=$(get_gecos_field "chfntest1" 4)

    assert_equals "$work_phone" "555-1234" "Hyphenated phone format preserved"
    assert_equals "$home_phone" "(555) 567-8901" "Parenthesized phone format preserved"
}

# Test 18: chfn targeting different user (root changing another user)
test_chfn_different_user() {
    log_test "Testing chfn with explicit username argument"

    # Create second test user
    create_test_user "chfntest3" "TestPass789"

    # Change GECOS for different user as root
    container_exec /usr/bin/chfn -f "Charlie Brown" chfntest3
    local exit_code=$?
    assert_success "$exit_code" "chfn on different user succeeded"

    local full_name=$(get_gecos_field "chfntest3" 1)
    assert_equals "$full_name" "Charlie Brown" "Different user's GECOS changed by root"

    # Verify first test user unchanged
    local user1_name=$(get_gecos_field "chfntest1" 1)
    assert_contains "$user1_name" "Alexander" "First user's GECOS unchanged"

    # Cleanup
    delete_test_user "chfntest3"
}

# Test 19: Verify complete GECOS structure after changes
test_gecos_structure_integrity() {
    log_test "Testing GECOS structure integrity after modifications"

    # Set all fields to known values
    container_exec /usr/bin/chfn -f "Test User" -r "Room1" -w "111-1111" -h "222-2222" -o "Info" chfntest1

    # Get full GECOS
    local gecos=$(get_gecos_full "chfntest1")

    # Count commas (should be 4 for 5 fields)
    local comma_count=$(echo "$gecos" | tr -cd ',' | wc -c)
    assert_equals "$comma_count" "4" "GECOS has correct comma separation"

    # Verify expected structure
    assert_equals "$gecos" "Test User,Room1,111-1111,222-2222,Info" "GECOS structure is correct"
}

# Test 20: Test chfn with non-existent user (should fail)
test_chfn_nonexistent_user() {
    log_test "Testing chfn with non-existent user"

    # Attempt to change GECOS for non-existent user
    # Note: Using redirect to file instead of command substitution due to exit code propagation issues
    local output
    output=$(container_exec /usr/bin/chfn -f "Nobody" nonexistentuser99999 2>&1)
    local exit_code=$?

    assert_failure "$exit_code" "chfn fails gracefully with non-existent user"
    assert_equals "$exit_code" "61" "chfn returns ENODATA (61) for non-existent user"
    assert_contains "$output" "user 'nonexistentuser99999' does not exist" "Error message indicates user does not exist"
}

# Test 21: Test pwaccess dependency
test_pwaccess_socket() {
    log_test "Testing pwaccess socket availability for user lookup"

    # chfn uses pwaccess_get_account_name() to get current user
    container_exec test -S /run/account/pwaccess-socket
    assert_success $? "pwaccess socket available for chfn user lookup"
}

# Test 22: Test full workflow - multiple sequential changes
test_sequential_changes() {
    log_test "Testing sequential GECOS field changes"

    # Create fresh user
    create_test_user "chfntest4" "TestPass000"

    # Sequential changes
    container_exec /usr/bin/chfn -f "Initial Name" chfntest4
    local name1=$(get_gecos_field "chfntest4" 1)
    assert_equals "$name1" "Initial Name" "First change applied"

    container_exec /usr/bin/chfn -r "100" chfntest4
    local room1=$(get_gecos_field "chfntest4" 2)
    assert_equals "$room1" "100" "Second change applied"

    local name2=$(get_gecos_field "chfntest4" 1)
    assert_equals "$name2" "Initial Name" "First field preserved after second change"

    container_exec /usr/bin/chfn -f "Updated Name" chfntest4
    local name3=$(get_gecos_field "chfntest4" 1)
    assert_equals "$name3" "Updated Name" "Third change applied"

    local room2=$(get_gecos_field "chfntest4" 2)
    assert_equals "$room2" "100" "Second field preserved after third change"

    # Cleanup
    delete_test_user "chfntest4"
}

# Test 23: Cleanup test users
test_cleanup_chfn_users() {
    log_test "Cleaning up chfn test users"

    delete_test_user "chfntest1"

    # Verify cleanup
    local user_gone=$(container_exec getent passwd chfntest1 && echo "no" || echo "yes")
    assert_equals "$user_gone" "yes" "Test user removed successfully"
}

# Run all tests
log_info "Starting chfn integration tests"
log_info "Running as root - PAM authentication bypassed"
echo ""

run_test test_chfn_binary_exists
run_test test_chfn_help
run_test test_chfn_version
run_test test_create_test_users
run_test test_pwupdd_socket
run_test test_chfn_full_name
run_test test_chfn_room
run_test test_chfn_work_phone
run_test test_chfn_home_phone
run_test test_chfn_other
run_test test_chfn_multiple_options
run_test test_chfn_clear_fields
run_test test_chfn_special_chars_name
run_test test_chfn_spaces_in_fields
run_test test_chfn_empty_gecos_initial
run_test test_chfn_long_values
run_test test_chfn_phone_formats
run_test test_chfn_different_user
run_test test_gecos_structure_integrity
run_test test_chfn_nonexistent_user
run_test test_pwaccess_socket
run_test test_sequential_changes
run_test test_cleanup_chfn_users

# Print summary
print_summary
