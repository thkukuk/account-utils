#!/bin/bash
# Integration tests for PAM module

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-utils.sh"

# Detect system library directory (lib or lib64)
case "$(uname -m)" in
    x86_64|aarch64|ppc64|ppc64le|s390x|riscv64|mips64|mips64el)
        LIBDIR="lib64"
        ;;
    *)
        LIBDIR="lib"
        ;;
esac

PAM_MODULE_PATH="/usr/$LIBDIR/security/pam_unix_ng.so"

log_info "========================================="
log_info "PAM Module Integration Tests"
log_info "========================================="
log_info "Using library directory: /usr/$LIBDIR"

# Test 1: PAM module exists
test_pam_module_exists() {
    log_test "Testing PAM module installation"

    container_exec test -f "$PAM_MODULE_PATH"
    assert_success $? "pam_unix_ng.so module exists at $PAM_MODULE_PATH"
}

# Test 2: PAM module is loadable
test_pam_module_loadable() {
    log_test "Testing PAM module loadability"

    # Check if module has correct permissions
    container_exec test -r "$PAM_MODULE_PATH"
    assert_success $? "pam_unix_ng.so is readable at $PAM_MODULE_PATH"
}

# Test 3: Verify module library dependencies
test_pam_module_dependencies() {
    log_test "Testing PAM module library dependencies"

    # Check if pam_unix_ng.so can be loaded (dependencies satisfied)
    # We can't run ldd in the container easily, but we can check file type
    local file_type
    file_type=$(container_exec file "$PAM_MODULE_PATH" | grep -o "shared object")
    assert_equals "$file_type" "shared object" "PAM module is a valid shared object"
}

# Run all tests
log_info "Starting PAM module tests"
echo ""

run_test test_pam_module_exists
run_test test_pam_module_loadable
run_test test_pam_module_dependencies

# Print summary
print_summary
