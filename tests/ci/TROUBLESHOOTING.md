## Advanced Debugging

### Enable Verbose Output

```bash
# In run-tests.sh, add set -x
sudo bash -x ./run-tests.sh

# Or modify test script
set -x  # Add to top of test script
```

### Inspect Container State

```bash
# Keep container running
sudo ./run-tests.sh --keep-container

# List all files in container (use actual container path from test output)
sudo find /tmp/account-utils-test-XXXXXX -ls

# Check all services
sudo systemd-nspawn -D /tmp/account-utils-test-XXXXXX

# Inside container:
systemctl list-units --all
systemctl list-sockets --all
```

### Debug Service Activation

```bash
# Get shell in container (use actual container path from test output)
sudo systemd-nspawn -D /tmp/account-utils-test-XXXXXX

# Inside container, enable debug logging for systemd
systemctl log-level debug

# Restart socket
systemctl restart pwaccessd.socket

# Watch logs in real-time
journalctl -u pwaccessd.socket -f
```

### Test Service Manually

```bash
# Start container (use actual container path from test output)
sudo systemd-nspawn -D /tmp/account-utils-test-XXXXXX -b

# In another terminal, get shell in container
sudo systemd-nspawn -D /tmp/account-utils-test-XXXXXX

# Inside container, stop automatic socket
systemctl stop pwaccessd.socket

# Run service manually
/usr/bin/pwaccessd --help
/usr/bin/pwaccessd --debug  # If debug flag exists
```

### Check Library Dependencies

```bash
# For each service binary
sudo systemd-nspawn -D /tmp/account-utils-test-container

ldd /usr/bin/pwaccessd | grep "not found"
ldd /usr/bin/pwupdd | grep "not found"
ldd /usr/lib/security/pam_unix_ng.so | grep "not found"

# If libraries missing, add to setup-container.sh
```

## Getting More Help

### Collect Debug Information

```bash
#!/bin/bash
# debug-info.sh - Collect debugging information

echo "=== System Info ==="
uname -a
systemd-nspawn --version

echo "=== Container Files ==="
ls -laR /tmp/account-utils-test-container/usr/bin/
ls -laR /tmp/account-utils-test-container/usr/lib/systemd/system/

echo "=== Service Dependencies ==="
ldd /tmp/account-utils-test-container/usr/bin/pwaccessd
ldd /tmp/account-utils-test-container/usr/bin/pwupdd

echo "=== Container Status ==="
machinectl status account-utils-test || echo "Container not running"

echo "=== Service Logs ==="
# Note: Replace XXXXXX with actual container path
sudo systemd-nspawn -D /tmp/account-utils-test-XXXXXX journalctl -u pwaccessd.socket
sudo systemd-nspawn -D /tmp/account-utils-test-XXXXXX journalctl -u pwupdd.socket
```

### Report an Issue

Include:
1. Output from debug-info.sh above
2. Full test output with `--verbose`
3. OS/distribution (e.g., Ubuntu 22.04, RHEL 9)
4. systemd version: `systemd-nspawn --version`
5. Build output: `ninja -C build 2>&1`
6. Test command used
7. Expected vs actual behavior

## Prevention

### Before Running Tests

```bash
# Checklist
[ ] Project is built: ls build/src/pwaccessd
[ ] Running as root: id -u returns 0
[ ] Have systemd-nspawn: which systemd-nspawn
[ ] Have disk space: df -h /tmp shows >100MB
[ ] No stale containers: sudo machinectl list
```

### Clean State

```bash
# Start fresh
sudo machinectl terminate account-utils-test 2>/dev/null || true
sudo rm -rf /tmp/account-utils-test-container
cd ../.. && meson compile -C build
cd tests/ci && sudo ./run-tests.sh
```

## Performance Issues

### Tests are Slow

**Normal timing:**
- Container setup: 2-5 seconds
- Container boot: 3-5 seconds
- Test execution: 10-30 seconds per suite
- Total: 1-2 minutes

**If slower:**

1. **Disk I/O**: Use faster disk or tmpfs
   ```bash
   # Use memory-backed filesystem
   sudo mount -t tmpfs -o size=100M tmpfs /tmp/account-utils-test-container
   ```

2. **CPU**: Reduce parallelism
   ```bash
   # Run tests sequentially
   for test in test-*.sh; do
       sudo ./"$test"
   done
   ```

3. **Network**: Disable if not needed
   ```bash
   # Add to nspawn command in run-tests.sh
   --network-veth=no
   ```

## Still Stuck?

1. Read TESTING.md for detailed documentation
2. Check example tests: test-pwaccessd.sh
3. Review container setup: setup-container.sh
4. Enable debug output: `set -x` in scripts
5. Ask for help with debug information collected above
