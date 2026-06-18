# Integration Testing Quick Start

## TL;DR

```bash
# Build the project
meson setup build
meson compile -C build

# Run all integration tests (requires root)
cd tests/ci
sudo ./run-tests.sh
```

## What This Does

1. Creates an isolated systemd-nspawn container in a secure temporary directory
2. Installs your built services (`pwaccessd`, `pwupdd`) into the container
3. Starts the container with systemd
4. Activates the socket-activated services
5. Runs comprehensive tests on:
   - Socket activation
   - User management
   - Password/shadow file modifications
   - PAM integration
6. Reports pass/fail for each test
7. Cleans up the container

## Expected Output

```
[INFO] Setting up test container at: /tmp/account-utils-test.AbC123XyZ
[INFO] Creating container directory structure
[INFO] Installing account-utils binaries and libraries
[INFO] Container setup complete
[INFO] Starting container: account-utils-test
[INFO] Waiting for container to boot
[INFO] Services are ready
[TEST] Running: test_socket_activation
[INFO] ✓ pwaccessd socket exists
...
=========================================
Test Summary
=========================================
Total tests run:    45
Tests passed:       45
Tests failed:       0
=========================================
All tests passed!
```

## Run Specific Tests

```bash
# Test only pwaccessd
sudo ./run-tests.sh test-pwaccessd

# Test only pwupdd
sudo ./run-tests.sh test-pwupdd

# Test only PAM integration
sudo ./run-tests.sh test-pam

# Test only chfn utility
sudo ./run-tests.sh test-chfn

# Test only chage utility
sudo ./run-tests.sh test-chage

# Test only chsh utility
sudo ./run-tests.sh test-chsh

# Test only expiry utility
sudo ./run-tests.sh test-expiry

# Test only passwd utility
sudo ./run-tests.sh test-passwd

# Test varlink protocol
sudo ./run-tests.sh test-varlink-protocol
```

## Debugging Failed Tests

### Keep the container after test failure

```bash
sudo ./run-tests.sh --keep-container
```

### Enter the container

The container path will be shown in the output. Use that path:

```bash
# From the test output, find the container path, then:
sudo systemd-nspawn -D /tmp/account-utils-test.XXXXXXXXXX

# Or use the container name:
sudo machinectl shell account-utils-test-PID-TIMESTAMP
```

### Check service status

```bash
# Start container
sudo systemd-nspawn -D /tmp/account-utils-test-container -b

# In another terminal
sudo machinectl shell account-utils-test

# Inside container:
systemctl status pwaccessd.socket
systemctl status pwupdd.socket
journalctl -u pwaccessd.socket
ls -la /run/account/
cat /etc/passwd
```

### View service logs

```bash
sudo machinectl shell account-utils-test /bin/bash
journalctl -u pwaccessd.socket --no-pager
journalctl -u pwupdd.socket --no-pager
```

## Common Issues

### "Container failed to start"

**Cause**: Missing systemd or library dependencies

**Fix**: Check the setup-container.sh script copied all required libraries

```bash
sudo systemd-nspawn -D /tmp/account-utils-test-container
# Try to start systemd manually to see errors
/usr/lib/systemd/systemd
```

### "Socket not ready"

**Cause**: Service binary missing dependencies or unit files not installed

**Fix**: Check service binaries and unit files

```bash
sudo systemd-nspawn -D /tmp/account-utils-test-container
ls -la /usr/bin/pwaccessd /usr/bin/pwupdd
ls -la /usr/lib/systemd/system/*.socket
ldd /usr/bin/pwaccessd
```

### "Permission denied"

**Cause**: Not running as root

**Fix**: All integration tests must run as root (for systemd-nspawn and passwd/shadow access)

```bash
sudo ./run-tests.sh  # Not just ./run-tests.sh
```

### Build not found

**Cause**: Project not built yet

**Fix**: Build the project first

```bash
cd /path/to/account-utils
meson setup build
ninja -C build
```

## Requirements

- Linux with systemd
- systemd-nspawn (part of systemd package)
- Root access
- Built project binaries
- ~50MB disk space for container

## Test Coverage

### pwaccessd Tests (10 tests)
- Socket activation mechanism
- Socket permissions (0666)
- User lookup functionality
- Passwd file integrity
- Shadow file security (600, root-owned)
- Service logging
- Socket restart resilience

### pwupdd Tests (13 tests)
- Accept=yes socket configuration
- Socket permissions
- MaxConnectionsPerSource limits
- Password change infrastructure
- Shell modification setup
- GECOS field access
- Concurrent connection handling
- Service binary availability

### PAM Tests (11 tests)
- PAM module installation
- Module loadability
- Configuration correctness
- Service dependencies
- User authentication setup
- Multiple user handling
- Configuration file verification

### chfn Tests (25 tests)
- Binary availability and options
- All command-line options (-f, -r, -w, -h, -o)
- GECOS field structure and parsing
- Varlink integration with pwupdd
- PAM authentication requirements
- Special characters handling
- Field length limits
- Multi-user scenarios

### chage Tests (33 tests)
- Binary availability and options
- All command-line options (-d, -E, -I, -i, -l, -m, -M, -W)
- Shadow field structure and parsing (9 fields)
- Date format validation (YYYY-MM-DD)
- Numeric value parsing
- Special value -1 (never/disabled)
- Varlink integration with pwupdd
- Root privilege requirements
- Interactive mode
- Multi-user scenarios

### chsh Tests (33 tests)
- Binary availability and options
- All command-line options (-s, -l, -h, -v)
- Passwd shell field (field 7)
- Shell list configuration (vendordir/shells)
- Shell validation and allowed lists
- Common shell paths
- Varlink integration with pwupdd
- PAM authentication requirements
- Interactive mode
- Permission model
- Multi-user scenarios

### expiry Tests (33 tests)
- Binary availability and options
- All command-line options (-c, -f, -h, -v)
- Password expiration checking
- Account vs password expiration
- Check mode (-c) - days until expiration
- Force mode (-f) - force password change
- pwaccess integration (check_expired method)
- PAM integration (chauthtok)
- Expiration status types and messages
- Shadow field dependency
- Permission model
- Multi-user scenarios

### passwd Tests (40 tests)
- Binary availability and options
- All command-line options (-d, -e, -I, -k, -l, -m, -M, -q, -s, -S, -u, -w)
- Password change operations
- Delete, expire, lock, unlock passwords
- Status display (P/NP/L codes)
- Stdin password reading
- Shadow field modifications
- pwupdd and pwaccess integration
- PAM integration and fallback
- Quiet and keep-tokens modes
- Permission model
- Multi-user scenarios

### Varlink Protocol Tests (7 tests)
- Socket accessibility
- Security attributes
- FileDescriptor naming
- Protocol test infrastructure
- Concurrent connection readiness
- Service instance lifecycle

**Total: 205 tests** across 9 test suites

## Next Steps

1. Run the tests: `sudo ./run-tests.sh`
2. Check the output for any failures
3. Read TESTING.md for detailed documentation
4. Add custom tests by creating test-*.sh files
5. Integrate into your CI/CD pipeline

## CI/CD Integration

### GitHub Actions

```yaml
- name: Run integration tests
  run: |
    cd tests/ci
    sudo ./run-tests.sh
```

### GitLab CI

```yaml
integration-tests:
  script:
    - cd tests/ci
    - ./run-tests.sh  # Run as root in CI
```

## Files Overview

```
tests/ci/
├── README.md                    # Architecture and detailed docs
├── TESTING.md                   # Comprehensive testing guide
├── QUICKSTART.md               # This file
├── run-tests.sh                # Main test runner
├── setup-container.sh          # Container setup script
├── test-utils.sh               # Common test utilities
├── test-pwaccessd.sh          # pwaccessd test suite
├── test-pwupdd.sh             # pwupdd test suite
├── test-pam.sh                # PAM integration tests
└── test-varlink-protocol.sh   # Varlink protocol tests
```

## Getting Help

- Read the full documentation: `TESTING.md`
- Check test utilities: `cat test-utils.sh`
- View test examples: `cat test-pwaccessd.sh`
