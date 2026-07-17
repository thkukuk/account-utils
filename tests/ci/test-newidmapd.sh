#!/bin/bash
# Integration tests for newidmapd varlink service, newuidmap and newgidmap

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-utils.sh"

log_info "========================================="
log_info "newidmapd / newuidmap / newgidmap Tests"
log_info "========================================="

# ---------------------------------------------------------------------------
# Socket and service sanity checks
# ---------------------------------------------------------------------------

test_newidmapd_socket_exists() {
    log_test "Testing newidmapd socket exists"

    container_exec test -S /run/account/newidmapd-socket
    assert_success $? "newidmapd socket exists at /run/account/newidmapd-socket"
}

test_newidmapd_socket_mode() {
    log_test "Testing newidmapd socket permissions"

    local mode
    mode=$(container_exec stat -c '%a' /run/account/newidmapd-socket)
    assert_equals "$mode" "666" "newidmapd socket has mode 666 (world-accessible)"

    local owner
    owner=$(container_exec stat -c '%U' /run/account/newidmapd-socket)
    assert_equals "$owner" "root" "newidmapd socket owned by root"
}

test_newidmapd_socket_fd_name() {
    log_test "Testing newidmapd socket FileDescriptorName"

    local fd_name
    fd_name=$(container_exec systemctl show newidmapd.socket -p FileDescriptorName --value)
    assert_equals "$fd_name" "varlink" "newidmapd socket FD name is 'varlink'"
}

test_newidmapd_binary_exists() {
    log_test "Testing newidmapd, newuidmap, newgidmap binaries are installed"

    container_exec test -x /usr/libexec/newidmapd
    assert_success $? "newidmapd binary exists and is executable"

    container_exec test -x /usr/bin/newuidmap
    assert_success $? "newuidmap binary exists and is executable"

    container_exec test -x /usr/bin/newgidmap
    assert_success $? "newgidmap binary exists and is executable"
}

# ---------------------------------------------------------------------------
# Varlink protocol tests (no user namespace required)
# ---------------------------------------------------------------------------

test_newidmapd_varlink_info() {
    log_test "Testing newidmapd varlink GetInfo"

    local info
    info=$(container_exec varlinkctl info unix:/run/account/newidmapd-socket)
    assert_success $? "varlinkctl info call succeeded"
    assert_contains "$info" "org.openSUSE.newidmapd" "newidmapd exposes org.openSUSE.newidmapd interface"
}

test_newidmapd_ping() {
    log_test "Testing newidmapd Ping method"

    local result
    result=$(container_exec varlinkctl call unix:/run/account/newidmapd-socket \
        org.openSUSE.newidmapd.Ping '{}')
    assert_success $? "Ping call succeeded"
    assert_contains "$result" '"Alive"' "Ping response contains Alive field"
}

test_newidmapd_invalid_pid() {
    log_test "Testing WriteMappings with non-existent PID"

    # PID 999999 almost certainly does not exist; newidmapd must reject it
    local rc=0
    container_exec varlinkctl call unix:/run/account/newidmapd-socket \
        org.openSUSE.newidmapd.WriteMappings \
        '{"PID":999999,"Map":"uid_map","MapRanges":[{"upper":0,"lower":0,"count":1}]}' \
        >/dev/null 2>&1 || rc=$?
    assert_failure $rc "WriteMappings with non-existent PID returns error"
}

test_newidmapd_invalid_map_name() {
    log_test "Testing WriteMappings with invalid Map value"

    local rc=0
    container_exec varlinkctl call unix:/run/account/newidmapd-socket \
        org.openSUSE.newidmapd.WriteMappings \
        '{"PID":1,"Map":"bad_map","MapRanges":[{"upper":0,"lower":0,"count":1}]}' \
        >/dev/null 2>&1 || rc=$?
    assert_failure $rc "WriteMappings with invalid Map name returns error"
}

# ---------------------------------------------------------------------------
# Helper: start a process in a fresh user namespace as a given user.
# Writes the PID to a file inside the container and returns it on stdout.
# The process has no uid_map or gid_map written yet.
# ---------------------------------------------------------------------------
start_userns_process() {
    local user="$1"
    local pid_file="$2"

    # unshare --user exec's sleep in the new user namespace; $! is that PID.
    # The shell exits immediately after, leaving sleep as an orphan adopted by init.
    # Use container_exec_user (nsenter --setuid/--setgid) instead of su: su fails via
    # nsenter with "failed to execute /bin/bash: Permission denied" because execve
    # returns EACCES after the credential switch in that execution context.
    container_exec_user "$user" /usr/bin/bash -c \
        "unshare --user /usr/bin/sleep 999 </dev/null >/dev/null 2>/dev/null & echo \$! > $pid_file"
    # Give the kernel a moment to finish setting up the namespace entry in /proc
    sleep 0.3
    container_exec cat "$pid_file"
}

# ---------------------------------------------------------------------------
# newuidmap / newgidmap – self-mapping
#
# newidmapd allows a user to map their own UID/GID (lower==peer_uid, count==1)
# unconditionally.  This is the simplest functional test.
# ---------------------------------------------------------------------------

test_newuidmap_self_mapping() {
    log_test "Testing newuidmap self-mapping"

    local testuser="newidmap_selfuid"
    create_test_user "$testuser" "TestPass123"

    local uid
    uid=$(container_exec id -u "$testuser")

    local pid_file="/tmp/newidmapd_test_selfuid_pid"
    local pid
    pid=$(start_userns_process "$testuser" "$pid_file")

    # Self-mapping: namespace UID == host UID == peer UID (uid == lower)
    local rc=0
    container_exec_user "$testuser" /usr/bin/bash -c \
        "newuidmap $pid $uid $uid 1" || rc=$?
    assert_success $rc "newuidmap self-mapping exits 0"

    # Kernel must have accepted the mapping
    local uid_map
    uid_map=$(container_exec cat "/proc/$pid/uid_map")
    assert_contains "$uid_map" "$uid" "uid_map written: host uid $uid present"

    container_exec /usr/bin/kill "$pid" 2>/dev/null || true
    container_exec rm -f "$pid_file"
    delete_test_user "$testuser"
}

test_newgidmap_self_mapping() {
    log_test "Testing newgidmap self-mapping (no subgid entry required)"

    local testuser="newidmap_selfgid"
    create_test_user "$testuser" "TestPass123"

    local gid
    gid=$(container_exec id -g "$testuser")

    local pid_file="/tmp/newidmapd_test_selfgid_pid"
    local pid
    pid=$(start_userns_process "$testuser" "$pid_file")

    # Self-mapping: namespace GID == host GID == peer GID (gid == lower)
    local rc=0
    container_exec_user "$testuser" /usr/bin/bash -c \
        "newgidmap $pid $gid $gid 1" || rc=$?
    assert_success $rc "newgidmap self-mapping exits 0"

    local gid_map
    gid_map=$(container_exec cat "/proc/$pid/gid_map")
    assert_contains "$gid_map" "$gid" "gid_map written: host gid $gid present"

    container_exec /usr/bin/kill "$pid" 2>/dev/null || true
    container_exec rm -f "$pid_file"
    delete_test_user "$testuser"
}

# ---------------------------------------------------------------------------
# newuidmap / newgidmap – subordinate ID range (requires /etc/subuid+subgid)
#
# Maps both the self-range and the full allocated subordinate range, which is
# the realistic use-case for running rootless containers.
# ---------------------------------------------------------------------------

test_newuidmap_subuid_range() {
    log_test "Testing newuidmap with subordinate UID range from /etc/subuid"

    local testuser="newidmap_subuid"
    local sub_count=65536
    create_test_user "$testuser" "TestPass123"

    local uid
    uid=$(container_exec id -u "$testuser")

    # useradd may have auto-allocated a sub-UID range; use it if present, else add one.
    local sub_start
    sub_start=$(container_exec bash -c \
        "awk -F: '\$1==\"${testuser}\" {print \$2; exit}' /etc/subuid")
    if [ -z "$sub_start" ]; then
        sub_start=200000
        container_exec bash -c "echo '${testuser}:${sub_start}:${sub_count}' >> /etc/subuid"
    else
        sub_count=$(container_exec bash -c \
            "awk -F: '\$1==\"${testuser}\" {print \$3; exit}' /etc/subuid")
    fi

    local pid_file="/tmp/newidmapd_test_subuid_pid"
    local pid
    pid=$(start_userns_process "$testuser" "$pid_file")

    # Map: uid 0 in ns -> own uid on host (self), uid 1..sub_count-1 in ns -> subuid range
    local rc=0
    container_exec_user "$testuser" /usr/bin/bash -c \
        "newuidmap $pid 0 $uid 1 1 $sub_start $((sub_count - 1))" || rc=$?
    assert_success $rc "newuidmap with subuid range exits 0"

    local uid_map
    uid_map=$(container_exec cat "/proc/$pid/uid_map")
    assert_contains "$uid_map" "$sub_start" "uid_map contains subordinate range start $sub_start"

    container_exec /usr/bin/kill "$pid" 2>/dev/null || true
    container_exec rm -f "$pid_file"
    # Remove the subuid entry
    container_exec bash -c \
        "grep -v '^${testuser}:' /etc/subuid > /etc/subuid.new && \
         cp /etc/subuid.new /etc/subuid && rm /etc/subuid.new"
    delete_test_user "$testuser"
}

test_newgidmap_subgid_range() {
    log_test "Testing newgidmap with subordinate GID range from /etc/subgid"

    local testuser="newidmap_subgid"
    local sub_count=65536
    create_test_user "$testuser" "TestPass123"

    local gid
    gid=$(container_exec id -g "$testuser")

    # useradd may have auto-allocated a sub-GID range; use it if present, else add one.
    local sub_start
    sub_start=$(container_exec bash -c \
        "awk -F: '\$1==\"${testuser}\" {print \$2; exit}' /etc/subgid")
    if [ -z "$sub_start" ]; then
        sub_start=300000
        container_exec bash -c "echo '${testuser}:${sub_start}:${sub_count}' >> /etc/subgid"
    else
        sub_count=$(container_exec bash -c \
            "awk -F: '\$1==\"${testuser}\" {print \$3; exit}' /etc/subgid")
    fi

    local pid_file="/tmp/newidmapd_test_subgid_pid"
    local pid
    pid=$(start_userns_process "$testuser" "$pid_file")

    local rc=0
    container_exec_user "$testuser" /usr/bin/bash -c \
        "newgidmap $pid 0 $gid 1 1 $sub_start $((sub_count - 1))" || rc=$?
    assert_success $rc "newgidmap with subgid range exits 0"

    local gid_map
    gid_map=$(container_exec cat "/proc/$pid/gid_map")
    assert_contains "$gid_map" "$sub_start" "gid_map contains subordinate range start $sub_start"

    container_exec /usr/bin/kill "$pid" 2>/dev/null || true
    container_exec rm -f "$pid_file"
    container_exec bash -c \
        "grep -v '^${testuser}:' /etc/subgid > /etc/subgid.new && \
         cp /etc/subgid.new /etc/subgid && rm /etc/subgid.new"
    delete_test_user "$testuser"
}

# ---------------------------------------------------------------------------
# Ownership enforcement: calling newuidmap for a process you don't own must fail
# ---------------------------------------------------------------------------

test_newuidmap_wrong_owner() {
    log_test "Testing newuidmap is rejected when caller does not own the target process"

    local owner="newidmap_owner"
    local attacker="newidmap_attacker"
    create_test_user "$owner"    "TestPass123"
    create_test_user "$attacker" "TestPass123"

    local attacker_uid
    attacker_uid=$(container_exec id -u "$attacker")

    # Start a user-namespace process owned by $owner
    local pid_file="/tmp/newidmapd_test_owner_pid"
    local pid
    pid=$(start_userns_process "$owner" "$pid_file")

    # $attacker tries to write uid_map for a process owned by $owner — must fail
    local rc=0
    container_exec_user "$attacker" /usr/bin/bash -c \
        "newuidmap $pid 0 $attacker_uid 1" >/dev/null 2>&1 || rc=$?
    assert_failure $rc "newuidmap rejected when caller does not own target PID"

    # The uid_map must still be empty (kernel rejects any write after a failed attempt
    # only if the failed attempt was a kernel-level rejection; newidmapd rejects before
    # touching /proc, so uid_map is still writable by the legitimate owner)
    local uid_map
    uid_map=$(container_exec cat "/proc/$pid/uid_map" 2>/dev/null || true)
    assert_equals "$uid_map" "" "uid_map remains unwritten after rejected attempt"

    container_exec /usr/bin/kill "$pid" 2>/dev/null || true
    container_exec rm -f "$pid_file"
    delete_test_user "$owner"
    delete_test_user "$attacker"
}

# ---------------------------------------------------------------------------
# Range outside subuid allocation must be rejected
# ---------------------------------------------------------------------------

test_newuidmap_out_of_range() {
    log_test "Testing newuidmap is rejected for ranges not in /etc/subuid"

    local testuser="newidmap_oor"
    local sub_start=400000
    local sub_count=65536
    create_test_user "$testuser" "TestPass123"

    local uid
    uid=$(container_exec id -u "$testuser")

    container_exec bash -c "echo '${testuser}:${sub_start}:${sub_count}' >> /etc/subuid"
    # No subgid entry added intentionally; we only test uid here

    local pid_file="/tmp/newidmapd_test_oor_pid"
    local pid
    pid=$(start_userns_process "$testuser" "$pid_file")

    # Request a range that starts well outside the allocated subuid range
    local bad_start=$(( sub_start + sub_count + 10000 ))
    local rc=0
    container_exec_user "$testuser" /usr/bin/bash -c \
        "newuidmap $pid 0 $uid 1 1 $bad_start 1000" >/dev/null 2>&1 || rc=$?
    assert_failure $rc "newuidmap rejected for range outside /etc/subuid allocation"

    container_exec /usr/bin/kill "$pid" 2>/dev/null || true
    container_exec rm -f "$pid_file"
    container_exec bash -c \
        "grep -v '^${testuser}:' /etc/subuid > /etc/subuid.new && \
         cp /etc/subuid.new /etc/subuid && rm /etc/subuid.new"
    delete_test_user "$testuser"
}

# ---------------------------------------------------------------------------
# CLI argument validation (no socket connection needed)
# ---------------------------------------------------------------------------

test_newuidmap_help() {
    log_test "Testing newuidmap --help and --version"

    local out
    out=$(container_exec newuidmap --help 2>&1 || true)
    assert_contains "$out" "newuidmap" "newuidmap --help mentions newuidmap"

    out=$(container_exec newuidmap --version 2>&1 || true)
    assert_contains "$out" "newuidmap" "newuidmap --version mentions newuidmap"
}

test_newgidmap_help() {
    log_test "Testing newgidmap --help and --version"

    local out
    out=$(container_exec newgidmap --help 2>&1 || true)
    assert_contains "$out" "newgidmap" "newgidmap --help mentions newgidmap"

    out=$(container_exec newgidmap --version 2>&1 || true)
    assert_contains "$out" "newgidmap" "newgidmap --version mentions newgidmap"
}

test_newuidmap_bad_args() {
    log_test "Testing newuidmap rejects malformed arguments"

    # No arguments at all
    local rc=0
    container_exec newuidmap >/dev/null 2>&1 || rc=$?
    assert_failure $rc "newuidmap with no arguments exits non-zero"

    # PID only, no mapping triples
    rc=0
    container_exec newuidmap 1 >/dev/null 2>&1 || rc=$?
    assert_failure $rc "newuidmap with PID but no triples exits non-zero"

    # Incomplete triple (not a multiple of 3 after the PID)
    rc=0
    container_exec newuidmap 1 0 0 >/dev/null 2>&1 || rc=$?
    assert_failure $rc "newuidmap with incomplete triple exits non-zero"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

log_info "Starting newidmapd / newuidmap / newgidmap tests"
echo ""

run_test test_newidmapd_socket_exists
run_test test_newidmapd_socket_mode
run_test test_newidmapd_socket_fd_name
run_test test_newidmapd_binary_exists
run_test test_newidmapd_varlink_info
run_test test_newidmapd_ping
run_test test_newidmapd_invalid_pid
run_test test_newidmapd_invalid_map_name
run_test test_newuidmap_help
run_test test_newgidmap_help
run_test test_newuidmap_bad_args
run_test test_newuidmap_self_mapping
run_test test_newgidmap_self_mapping
run_test test_newuidmap_subuid_range
run_test test_newgidmap_subgid_range
run_test test_newuidmap_wrong_owner
run_test test_newuidmap_out_of_range

print_summary
