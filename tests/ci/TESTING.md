# Integration Testing Guide

## Overview

The integration test framework tests `pwaccessd` and `pwupdd` services in isolated systemd-nspawn containers. Each test run creates a unique, secure temporary directory to ensure parallel test execution is safe and to prevent security issues from predictable paths.

## Why systemd-nspawn?

- **Full systemd support**: Services can be socket-activated exactly as in production
- **Lightweight**: Much faster than full VMs
- **Isolation**: Complete filesystem isolation, safe for passwd/shadow modifications
- **Native systemd**: Same activation mechanism as production
- **Easy debugging**: Can enter containers and inspect state

## Quick Start

### Prerequisites

1. Root access (required for systemd-nspawn and passwd/shadow modifications)
2. systemd with nspawn support
3. Built project (`meson setup build && ninja -C build`)

### Run All Tests

```bash
cd tests/ci
sudo ./run-tests.sh
```

### Run Specific Test Suite

```bash
sudo ./run-tests.sh test-pwaccessd
sudo ./run-tests.sh test-pwupdd
sudo ./run-tests.sh test-pam
```

### Keep Container for Debugging

```bash
sudo ./run-tests.sh --keep-container
```

## Test Suites

### 1. pwaccessd Tests (`test-pwaccessd.sh`)

Tests the socket-activated read-only service:

- Socket activation and permissions
- User lookup functionality
- Passwd/shadow file access
- Service logging
- Socket restart resilience
- File integrity checks

### 2. pwupdd Tests (`test-pwupdd.sh`)

Tests the inetd-style write service:

- Accept=yes socket configuration
- Concurrent connection handling
- Password change capabilities
- Shell modification setup
- GECOS field access
- MaxConnectionsPerSource limits

### 3. PAM Module Tests (`test-pam.sh`)

Tests the PAM integration:

- Module installation and loadability
- PAM configuration correctness
- Service dependencies
- User authentication setup
- Multiple user handling

## Architecture Details

### Container Structure

Each test run creates a unique, secure temporary directory:

```
/tmp/account-utils-test.XXXXXXXXXX/  # Unique per test run
├── etc/
│   ├── passwd              # Test passwd file
│   ├── shadow              # Test shadow file (mode 600)
│   ├── group               # Test group file
│   ├── pam.d/              # PAM configurations
│   │   ├── system-auth
│   │   └── passwd
│   └── account-utils/      # Service configurations
├── usr/
│   ├── bin/                # Service binaries (pwaccessd, pwupdd)
│   ├── lib/                # Shared libraries
│   │   └── security/       # PAM modules
│   └── lib/systemd/system/ # Unit files
├── run/
│   └── account/            # Socket directory
│       ├── pwaccess-socket
│       └── pwupd-socket
└── var/log/                # Service logs
```

### Test Workflow

1. **Build Phase**: Compile project with meson/ninja
2. **Setup Phase**: 
   - Create minimal container filesystem
   - Copy systemd and essential binaries
   - Install built services and libraries
   - Configure systemd units
   - Set up PAM configurations
3. **Boot Phase**: 
   - Start container with systemd
   - Wait for systemd initialization
   - Verify socket activation
4. **Test Phase**: 
   - Execute test suites
   - Each test suite runs independently
   - Tests interact with services via sockets
5. **Cleanup Phase**: 
   - Terminate container
   - Remove container directory (unless --keep-container)

## Writing Custom Tests

### Test Script Template

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-utils.sh"

log_info "====================================="
log_info "My Custom Test Suite"
log_info "====================================="

test_something() {
    log_test "Testing something specific"
    
    # Setup
    create_test_user "testuser" "testpass"
    
    # Execute
    local result=$(container_exec some_command)
    
    # Assert
    assert_equals "$result" "expected" "Description"
    
    # Cleanup
    delete_test_user "testuser"
}

# Run tests
run_test test_something

# Print summary
print_summary
```

### Available Utilities (test-utils.sh)

#### Logging
- `log_info "message"` - Info message (green)
- `log_warn "message"` - Warning message (yellow)
- `log_error "message"` - Error message (red)
- `log_test "message"` - Test message (yellow)

#### Container Operations
- `container_exec command [args...]` - Execute command as root in container
- `container_exec_user username command [args...]` - Execute as specific user
- `wait_for_service servicename [timeout]` - Wait for systemd service
- `wait_for_socket socketpath [timeout]` - Wait for Unix socket

#### User Management
- `create_test_user username password [uid]` - Create test user in container
- `delete_test_user username` - Remove test user from container

#### Assertions
- `assert_equals actual expected [message]` - Assert equality
- `assert_not_equals actual expected [message]` - Assert inequality
- `assert_success exit_code [message]` - Assert command succeeded
- `assert_failure exit_code [message]` - Assert command failed
- `assert_contains haystack needle [message]` - Assert substring present

#### Test Management
- `run_test test_function_name` - Execute a test function
- `print_summary` - Print test results summary
- `cleanup_test_users` - Remove all standard test users

## Debugging Failed Tests

### View Container Logs

```bash
# Keep container after test
sudo ./run-tests.sh --keep-container test-pwaccessd

# Enter container
sudo systemd-nspawn -D /tmp/account-utils-test-container

# Inside container:
journalctl -u pwaccessd.socket
journalctl -u pwupdd.socket
systemctl status pwaccessd.socket
systemctl status pwupdd.socket
```

### Manual Container Testing

```bash
# Setup and start container
sudo ./setup-container.sh
sudo systemd-nspawn -D /tmp/account-utils-test-container -b

# In another terminal, execute commands:
sudo machinectl shell account-utils-test /bin/bash

# Inside container:
systemctl status
ls -la /run/account/
cat /etc/passwd
```

### Common Issues

#### Container Fails to Start
- **Symptom**: Container boot fails or hangs
- **Solution**: Check systemd and library dependencies
- **Debug**: `sudo systemd-nspawn -D /tmp/account-utils-test-container` (without -b)

#### Sockets Not Created
- **Symptom**: `/run/account/*-socket` files missing
- **Solution**: Check unit files are installed, verify socket activation
- **Debug**: `container_exec systemctl list-sockets`

#### Services Not Starting
- **Symptom**: Socket exists but service doesn't activate
- **Solution**: Check binary dependencies with `ldd`
- **Debug**: `container_exec journalctl -xe`

#### Permission Denied
- **Symptom**: Tests can't modify passwd/shadow
- **Solution**: Ensure running as root, check file permissions
- **Debug**: Check shadow file is mode 600, owned by root

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Integration Tests

on: [push, pull_request]

jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y meson ninja-build libpam0g-dev libvarlink-dev
      
      - name: Build
        run: |
          meson setup build
          ninja -C build
      
      - name: Run integration tests
        run: |
          cd tests/ci
          sudo ./run-tests.sh
```

### Local Development

Add to your `.git/hooks/pre-push`:

```bash
#!/bin/bash
echo "Running integration tests..."
cd tests/ci
sudo ./run-tests.sh
exit $?
```

## Performance Considerations

- Container creation: ~2-5 seconds
- Container boot: ~3-5 seconds  
- Each test suite: ~10-30 seconds
- Total runtime: ~1-2 minutes for all tests

## Security Notes

1. Tests must run as root (systemd-nspawn requirement)
2. Container is fully isolated from host
3. No host passwd/shadow files are ever modified
4. Container uses separate /etc and /run directories
5. Test cleanup removes all container data

## Future Enhancements

- [ ] Add varlink client tests for direct protocol testing
- [ ] Add performance/load tests for concurrent connections
- [ ] Add security tests (privilege escalation, etc.)
- [ ] Add failure injection tests
- [ ] Add tests for configuration file parsing
- [ ] Integration with CI/CD pipelines
- [ ] Container image caching for faster runs
- [ ] Parallel test execution
