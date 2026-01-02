#!/bin/bash

# Diagnostic script to capture traffic flow for VLAN container internet issue
# This helps understand why shim delivers Mac traffic but not WAN replies

echo "=== VLAN Container Traffic Flow Diagnostics ==="
echo ""
echo "This script will:"
echo "1. Capture traffic on shim interface"
echo "2. Capture traffic inside container macvlan interface"
echo "3. Ping 8.8.8.8 from container"
echo "4. Show where packets are getting dropped"
echo ""
echo "Press Ctrl+C to stop all captures"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "Stopping captures..."
    kill $TCPDUMP1_PID 2>/dev/null
    kill $TCPDUMP2_PID 2>/dev/null
    exit 0
}

trap cleanup INT TERM

# Check if container is running
if ! docker ps | grep -q unifi-routing-fixer; then
    echo "ERROR: unifi-routing-fixer container not running"
    echo "Run install script first to deploy containers"
    exit 1
fi

# Create temp files for output
SHIM_OUTPUT="/tmp/shim-capture.txt"
CONTAINER_OUTPUT="/tmp/container-capture.txt"

> $SHIM_OUTPUT
> $CONTAINER_OUTPUT

echo "Starting captures..."
echo ""

# Capture 1: Shim interface
echo "[Capture 1] Watching unifi-shim interface..."
sudo tcpdump -i unifi-shim -n icmp 2>&1 | tee $SHIM_OUTPUT &
TCPDUMP1_PID=$!

sleep 2

# Capture 2: Container macvlan interface
echo "[Capture 2] Watching container eth1 (macvlan) interface..."
sudo docker exec unifi-routing-fixer tcpdump -i eth1 -n icmp 2>&1 | tee $CONTAINER_OUTPUT &
TCPDUMP2_PID=$!

sleep 2

echo ""
echo "=== Starting ping test from container ==="
echo "Pinging 8.8.8.8 from container..."
echo ""

sudo docker exec unifi-routing-fixer ping -c 3 8.8.8.8

sleep 3

echo ""
echo "=== Traffic Analysis ==="
echo ""

# Analyze shim capture
echo "--- Shim Interface (unifi-shim) ---"
SHIM_REQUESTS=$(grep "192.168.240.2 > 8.8.8.8" $SHIM_OUTPUT | wc -l)
SHIM_REPLIES=$(grep "8.8.8.8 > 192.168.240.2" $SHIM_OUTPUT | wc -l)
echo "ICMP requests seen: $SHIM_REQUESTS"
echo "ICMP replies seen: $SHIM_REPLIES"

if [ $SHIM_REPLIES -gt 0 ]; then
    echo "✓ WAN replies ARE reaching shim interface"
    echo "⚠ Problem: Shim not forwarding to container macvlan"
else
    echo "✗ WAN replies NOT reaching shim interface"
    echo "⚠ Problem: Routing issue before shim"
fi

echo ""

# Analyze container capture
echo "--- Container Interface (eth1 macvlan) ---"
CONTAINER_REQUESTS=$(grep "192.168.240.2 > 8.8.8.8" $CONTAINER_OUTPUT | wc -l)
CONTAINER_REPLIES=$(grep "8.8.8.8 > 192.168.240.2" $CONTAINER_OUTPUT | wc -l)
echo "ICMP requests sent: $CONTAINER_REQUESTS"
echo "ICMP replies received: $CONTAINER_REPLIES"

if [ $CONTAINER_REQUESTS -gt 0 ] && [ $CONTAINER_REPLIES -eq 0 ]; then
    echo "✗ Container sending requests but NOT receiving replies"
fi

echo ""
echo "=== Diagnosis ==="

if [ $SHIM_REPLIES -gt 0 ] && [ $CONTAINER_REPLIES -eq 0 ]; then
    echo "⚠ ISSUE IDENTIFIED:"
    echo "  - WAN replies reach shim interface"
    echo "  - But shim does NOT forward to container macvlan"
    echo ""
    echo "Possible causes:"
    echo "  1. Two macvlan interfaces on same parent (br0) cannot communicate"
    echo "  2. Bridge proxy_arp not configured correctly"
    echo "  3. Missing iptables FORWARD rule for shim→container"
    echo "  4. ARP issue - shim doesn't know container's MAC on macvlan"
elif [ $SHIM_REPLIES -eq 0 ]; then
    echo "⚠ ISSUE IDENTIFIED:"
    echo "  - WAN replies never reach shim interface"
    echo "  - Routing table issue or policy routing problem"
fi

echo ""
echo "=== Next Steps ==="
echo ""
echo "Run the following commands to investigate further:"
echo ""
echo "# Check if shim and container can ARP each other"
echo "ip neigh show | grep 192.168.240.2"
echo "sudo docker exec unifi-routing-fixer ip neigh"
echo ""
echo "# Check bridge forwarding"
echo "brctl show br0"
echo "cat /sys/class/net/br0/bridge/proxy_arp"
echo ""
echo "# Check iptables FORWARD chain"
echo "sudo iptables -L FORWARD -n -v | grep 192.168.240"

cleanup
