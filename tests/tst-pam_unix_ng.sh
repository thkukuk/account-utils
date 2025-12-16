#!/bin/bash

# --- Configuration ---
TEST_USER="pam_testuser"
TEST_PASSWD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
PAM_SERVICE="pam_unix_ng-test" # Service to test authentication against

EXPIRY_DAYS=5    # The maximum number of days the password is valid (-M flag)
WARNING_DAYS=7   # The number of days before expiry to start warning (-W flag)

# --- Functions ---

function cleanup {
    echo "--- Cleaning up: Removing $TEST_USER"
    if id "$TEST_USER" &>/dev/null; then
        userdel -r "$TEST_USER" &>/dev/null
    fi
}

# Ensure cleanup runs on exit or script failure
trap cleanup EXIT

function expect_success {
    if [ $? -eq 0 ]; then
        echo -e "\033[32mSUCCESS:\033[0m $1"
    else
        echo -e "\033[31mFAILURE:\033[0m $1"
        exit 1
    fi
}

function expect_failure {
    if [ $? -ne 0 ]; then
        echo -e "\033[32mSUCCESS:\033[0m $1"
    else
        echo -e "\033[31mFAILURE:\033[0m $1"
        exit 1
    fi
}


# Create Test User
echo "--- Creating user '$TEST_USER' and setting password"
# user with empty password
useradd -m "$TEST_USER" -p ''
expect_success "User creation"

echo "--- Login with empty password (DISALLOW_NULL_AUTTHOK)"
echo '' | pamtester "$PAM_SERVICE" "$TEST_USER" "authenticate(PAM_DISALLOW_NULL_AUTHTOK)"
expect_failure "Failure with empty password"

echo "--- Login with empty password (nullok)"
# XXX need of echo is a bug
echo '' | pamtester "$PAM_SERVICE" "$TEST_USER" authenticate
expect_success "Login with empty password"

# Set the 12-character password non-interactively
echo "$TEST_USER:$TEST_PASSWD" | chpasswd
expect_success "Password set to 12 characters"

echo "--- Verifying initial login"
echo "$TEST_PASSWD" | pamtester "$PAM_SERVICE" "$TEST_USER" authenticate acct_mgmt open_session close_session
expect_success "Initial login successful via pamtester"

echo "--- Verifying password expiration warning message"
# The message pattern we expect depends on EXPIRY_DAYS
EXPECTED_WARNING_PATTERN="your password will expire in $EXPIRY_DAYS days"
echo "---- Setting password expiry periods"
chage -M "$EXPIRY_DAYS" "$TEST_USER"
expect_success "Set maximum password age to $EXPIRY_DAYS days"

chage -W "$WARNING_DAYS" "$TEST_USER"
expect_success "Set password warning period to $WARNING_DAYS days"

echo "Current password settings for $TEST_USER:"
chage -l "$TEST_USER"

# Run pamtester in verbose mode and pipe output to grep
if echo "$TEST_PASSWD" | pamtester --verbose "$PAM_SERVICE" "$TEST_USER" authenticate acct_mgmt 2>&1 | grep -q -i "$EXPECTED_WARNING_PATTERN"; then
    expect_success "Warning message successfully found: '$EXPECTED_WARNING_PATTERN'"
else
    # Try one last time and print the full output for debugging failure
    echo "Debugging failure: Full pamtester output:"
    echo "$TEST_PASSWD" | pamtester --verbose "$PAM_SERVICE" "$TEST_USER" authenticate acct_mgmt 2>&1
    # Check for the exit code of grep -q, not the full command.
    expect_success "Warning message verification failed (check output above)"
fi

echo "--- Verify inactive password"
# The message pattern we expect depends on EXPIRY_DAYS
EXPECTED_EXPIRED_PASSWORD_MSG="Authentication token expired"
echo "---- Setting password expiry periods"
chage --lastday "$(date -d "14 days ago" +%Y-%m-%d)" "$TEST_USER"
expect_success "Set lastday to 14 days ago"
chage --maxdays 7 "$TEST_USER"
expect_success "Set maximum password age to $EXPIRY_DAYS days"
chage --inactive 4 "$TEST_USER"
expect_success "Set password inactive days to 4"
echo "Current password settings for $TEST_USER:"
chage -l "$TEST_USER"
# Run pamtester in verbose mode and pipe output to grep
if echo "$TEST_PASSWD" | pamtester --verbose "$PAM_SERVICE" "$TEST_USER" authenticate acct_mgmt 2>&1 | grep -q -i "$EXPECTED_EXPIRED_PASSWORD_MSG"; then
    expect_success "Expired message successfully found: '$EXPECTED_EXPIRED_PASSWORD_MSG'"
else
    # Try one last time and print the full output for debugging failure
    echo "Debugging failure: Full pamtester output:"
    echo "$TEST_PASSWD" | pamtester --verbose "$PAM_SERVICE" "$TEST_USER" authenticate acct_mgmt 2>&1
    # Check for the exit code of grep -q, not the full command.
    expect_success "Warning message verification failed (check output above)"
fi

echo "--- Script finished successfully"
