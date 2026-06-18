# Integration Test Framework

This directory contains an integration test framework for testing `pwaccessd` and `pwupdd` services in isolated systemd-nspawn containers.

## Architecture

The test framework uses **systemd-nspawn** containers to provide:
- Full systemd support for socket activation
- Isolated /etc/passwd and /etc/shadow files
- Minimal overhead compared to VMs
- Clean environment for each test run
- Secure temporary directories (unique per run)
- Support for parallel test execution

## Components

### 1. Container Setup (`setup-container.sh`)
Creates a minimal systemd-nspawn container in a secure temporary directory with:
- Base system files (passwd, shadow, group, etc.)
- Systemd units for socket activation
- Test binaries and libraries
- Restricted permissions (mode 700)
- Unique path per test run (supports parallel execution)

### 2. Test Runner (`run-tests.sh`)
Orchestrates test execution:
- Builds the project
- Sets up the container environment
- Executes individual test suites
- Collects and reports results
- Cleans up containers

### 3. Test Suites
Individual test scripts for each service and utility:
- `test-pwaccessd.sh` - Tests for pwaccessd service
- `test-pwupdd.sh` - Tests for pwupdd service
- `test-pam.sh` - Tests for PAM module integration
- `test-chfn.sh` - Tests for chfn utility (change finger information)
- `test-chage.sh` - Tests for chage utility (change password aging)
- `test-chsh.sh` - Tests for chsh utility (change login shell)
- `test-expiry.sh` - Tests for expiry utility (check password expiration)
- `test-passwd.sh` - Tests for passwd utility (change user password)
- `test-varlink-protocol.sh` - Tests for varlink protocol infrastructure

### 4. Test Utilities (`test-utils.sh`)
Common functions for:
- Container management
- Service control
- Result verification
- Logging

## Requirements

- systemd-nspawn (part of systemd)
- Root privileges (for container creation and passwd/shadow modification)
- meson/ninja for building the project

## Usage

### Run all tests:
```bash
sudo ./run-tests.sh
```

### Run specific test suite:
```bash
sudo ./run-tests.sh test-pwaccessd
```

### Keep container for debugging:
```bash
sudo ./run-tests.sh --keep-container
```

### Enter test container manually:
```bash
# Use the container path shown in test output
sudo systemd-nspawn -D /tmp/account-utils-test.XXXXXXXXXX --boot
```

## Test Workflow

1. Build project in host system
2. Create fresh container with minimal base system
3. Install built binaries and libraries into container
4. Start container with systemd
5. Execute tests that interact with services via sockets
6. Verify passwd/shadow modifications
7. Collect results and logs
8. Clean up container (unless --keep-container specified)

## Writing Tests

Test scripts should:
1. Source `test-utils.sh` for common functions
2. Set up test users if needed
3. Start required services
4. Execute test operations via varlink sockets
5. Verify expected outcomes
6. Clean up test data
7. Report PASS/FAIL results

Example:
```bash
#!/bin/bash
source "$(dirname "$0")/test-utils.sh"

test_password_verification() {
    # Create test user
    create_test_user "testuser" "testpass"
    
    # Verify password via pwaccessd
    result=$(verify_password "testuser" "testpass")
    
    assert_equals "$result" "success"
}

run_test test_password_verification
```

## Container Structure

```
container-root/
├── etc/
│   ├── passwd
│   ├── shadow
│   ├── group
│   ├── pam.d/
│   └── account-utils/
├── usr/
│   ├── bin/          # Test utilities
│   ├── lib/          # Libraries
│   └── lib/systemd/system/  # Unit files
├── run/
│   └── account/      # Socket directory
└── var/
    └── log/          # Service logs
```
