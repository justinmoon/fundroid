#!/usr/bin/env bash
# Test script to verify graceful shutdown with SIGTERM

set -euo pipefail

echo "Starting QEMU in background..."
./run.sh > /tmp/qemu-output.txt 2>&1 &
qemu_pid=$!

echo "QEMU PID: $qemu_pid"
echo "Waiting 6 seconds for boot and heartbeats..."
sleep 6

echo "Sending SIGTERM to QEMU (init should see this via QEMU's monitor)..."
kill -TERM $qemu_pid

echo "Waiting for shutdown..."
wait $qemu_pid
exit_code=$?

echo ""
echo "========== QEMU OUTPUT =========="
cat /tmp/qemu-output.txt
echo ""
echo "========== TEST RESULTS =========="
echo "Exit code: $exit_code"

if grep -q "Signal handler installed for SIGTERM" /tmp/qemu-output.txt; then
    echo "✓ SIGTERM handler installed"
else
    echo "✗ SIGTERM handler NOT installed"
fi

if grep -q "\[SHUTDOWN\] Received SIGTERM" /tmp/qemu-output.txt; then
    echo "✓ Shutdown initiated"
else
    echo "✗ Shutdown NOT initiated (might need kernel parameter)"
fi

if grep -q "Unmounting" /tmp/qemu-output.txt; then
    echo "✓ Filesystems unmounted"
else
    echo "✗ Filesystems NOT unmounted"
fi
