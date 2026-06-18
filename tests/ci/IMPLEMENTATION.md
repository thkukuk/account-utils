# Integration Test Framework Implementation Summary

## Overview

A comprehensive integration test framework has been implemented for the account-utils project, enabling safe testing of systemd socket-activated services (`pwaccessd` and `pwupdd`) that modify system files (`/etc/passwd` and `/etc/shadow`).

## Solution Architecture

### Technology Choice: systemd-nspawn

- **Full systemd support**: Native socket activation exactly as in production
- **Lightweight**: 2-5 second startup vs 30+ seconds for VMs
- **Complete isolation**: Separate /etc, /run, /var directories
- **Easy debugging**: Can enter and inspect running containers
- **No special setup**: Part of standard systemd installation
- **Same kernel**: No emulation overhead

## Components Delivered

### 1. Core Infrastructure (3 files)

**setup-container.sh**
- Creates minimal systemd-nspawn container
- Copies systemd, essential binaries, and dependencies
- Installs built services and libraries
- Configures systemd units and PAM
- Sets up test user database

**run-tests.sh**
- Main test orchestrator
- Handles container lifecycle
- Executes test suites
- Supports selective test execution
- Cleanup and error handling

**test-utils.sh**
- Logging utilities (info, warn, error, test)
- Container execution helpers
- Service/socket wait functions
- User management functions
- Assertion framework (equals, contains, success, failure)
- Test summary reporting

### 2. Test Suites

**test-pwaccessd.sh**
- Socket activation mechanism
- Socket permissions and security
- User lookup functionality (root and regular users)
- Multiple concurrent user lookups
- Passwd/shadow file integrity
- Service logging verification
- Socket restart resilience

**test-pwupdd.sh**
- Socket activation mechanism
- Accept=yes socket configuration (inetd-style)
- Socket permissions and security
- Socket directory structure
- MaxConnectionsPerSource limits
- Concurrent connection handling
- Password change infrastructure setup
- Shell change infrastructure setup
- GECOS modification infrastructure setup
- Service binary verification
- Varlink protocol readiness
- Service restart resilience
- Service logging verification

**test-pam.sh**
- PAM module installation verification
- PAM module loadability (dlopen test)
- PAM module dependencies (library linking)

**test-chfn.sh**
- Binary existence and help/version options
- Test user creation and pwupdd socket readiness
- All GECOS field options (-f, -r, -w, -h, -o)
- Multiple field changes in single command
- Clearing GECOS fields
- Special characters in fields
- Spaces in field values
- Empty initial GECOS handling
- Long field value handling
- Various phone number formats
- Different user modifications
- GECOS structure integrity (5-field format)
- Non-existent user error handling
- pwaccess socket verification
- Sequential field changes
- User cleanup

**test-chage.sh**
- Binary existence and help/version options
- Test user creation and pwupdd socket readiness
- All command-line options (-m, -M, -W, -I, -E, -d, -l)
- Minimum password age setting
- Maximum password age setting
- Password warning period
- Password inactivity period
- Account expiration date
- Last password change date
- Multiple option combinations
- Disabled values (-1 handling)
- Expiration date "never" value
- List mode (-l) for displaying settings
- Zero values handling
- Different user modifications
- Shadow structure integrity (9-field format)
- Non-existent user error handling
- pwaccess socket verification
- Sequential shadow field changes
- Shadow file security (permissions)
- User cleanup

**test-chsh.sh**
- Binary existence and help/version options
- Test user creation and pwupdd socket readiness
- Shell change operations (-s)
- Preservation of other passwd fields
- Absolute path handling
- Different user modifications
- List shells option (-l)
- Valid shell verification
- Passwd structure integrity (7-field format)
- Sequential shell changes
- Shell absolute path requirements
- Independent shell changes per user
- Common shells existence (/bin/bash, /bin/sh, etc.)
- Non-existent user error handling
- pwaccess socket verification
- Root user shell changes
- User cleanup

**test-expiry.sh**
- Binary existence and help/version options
- Test user creation and pwaccess socket readiness
- Check mode for non-expired accounts
- Check mode for specific users
- Check mode for expired passwords
- Account expiration detection
- Force password change option (-f)
- Option conflict detection
- Argument validation
- Too many arguments error handling
- Non-existent user error handling
- Multiple user expiration scenarios
- Shadow field dependencies (lstchg, max, expire, inact)
- Recent password scenarios
- Maximum password age scenarios
- Warning period scenarios
- Root user expiration checks
- User cleanup

**test-passwd.sh**
- Binary existence and help/version options
- Test user creation and pwupdd socket readiness
- Password reading from stdin
- Lock password operation (-l)
- Unlock password operation (-u)
- Delete password operation (-d)
- Expire password operation (-e)
- Status display operation (-S)
- Lock/unlock cycle testing
- Different user password operations
- Sequential password operations
- Expire then change scenarios
- Delete then lock scenarios
- Independent password changes per user
- Non-existent user error handling
- pwaccess socket verification
- User cleanup

**test-varlink-protocol.sh**
- Varlink socket availability verification
- Socket security and permissions
- Socket file descriptor names
- Protocol test infrastructure readiness
- Varlink GetInfo method support
- Concurrent connection infrastructure
- GetUserEntry method infrastructure
- VerifyPassword method infrastructure
- ChangePassword method infrastructure
- ChangeShell method infrastructure
- ChangeGECOS method infrastructure
- Error handling infrastructure
- Concurrent connection testing infrastructure

### 3. Documentation (4 files)

**README.md** - Architecture overview and component description  
**TESTING.md** - Comprehensive testing guide with debugging tips  
**QUICKSTART.md** - Quick start guide for immediate use  
**IMPLEMENTATION.md** - This file, implementation summary

## Usage Examples

### Basic Usage
```bash
cd tests/ci
sudo ./run-tests.sh
```

### Selective Testing
```bash
sudo ./run-tests.sh test-pwaccessd  # Only pwaccessd tests
```

### Debugging
```bash
sudo ./run-tests.sh --keep-container
sudo systemd-nspawn -D /tmp/account-utils-test-container
```

### CI/CD Integration
```yaml
# GitHub Actions
- name: Integration tests
  run: |
    cd tests/ci
    sudo ./run-tests.sh
```

## How It Works

### Workflow
1. **Build Phase**: Project built with meson/ninja
2. **Setup Phase**: 
   - Create container directory structure
   - Copy systemd and essential binaries
   - Install service binaries and libraries
   - Configure systemd units
   - Set up PAM configuration
3. **Boot Phase**:
   - Start container with systemd
   - Wait for systemd initialization
   - Verify socket activation
4. **Test Phase**:
   - Execute test suites
   - Each test uses assertion framework
   - Results collected and reported
5. **Cleanup Phase**:
   - Terminate container
   - Remove container directory (optional)

### Container Structure
```
/tmp/account-utils-test-container/
├── etc/
│   ├── passwd, shadow, group      # Test user database
│   ├── pam.d/                     # PAM configurations
│   └── account-utils/             # Service configs
├── usr/
│   ├── bin/                       # Service binaries
│   ├── lib/                       # Libraries
│   │   └── security/              # PAM modules
│   └── lib/systemd/system/        # Unit files
├── run/account/                   # Socket directory
└── var/log/                       # Service logs
```
