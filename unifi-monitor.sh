#!/bin/bash
#
# UniFi Container Network Monitor and Self-Healing Service
# Monitors UniFi controller health and automatically recovers from network disruptions
#

COMPOSE_DIR="/home/pi/.firewalla/run/docker/unifi"
LOG_FILE="/var/log/unifi-monitor.log"
MAX_LOG_SIZE=10485760  # 10MB

# Read configuration from saved config
if [ -f "$COMPOSE_DIR/config.env" ]; then
    source "$COMPOSE_DIR/config.env"
else
    # Fallback defaults
    CONTROLLER_IP="192.168.240.2"
    SHIM_IP="192.168.240.254"
    PARENT_INTERFACE="br0"
    IS_VLAN="false"
    NETWORK_BASE="192.168.240.0"
    NETWORK_CIDR="24"
fi

# Rotate log if too large
rotate_log() {
    if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        touch "$LOG_FILE"
    fi
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Check if containers are running
check_containers() {
    UNIFI_RUNNING=$(docker ps --filter "name=unifi$" --filter "status=running" -q)
    UNIFI_DB_RUNNING=$(docker ps --filter "name=unifi-db" --filter "status=running" -q)

    if [ -z "$UNIFI_RUNNING" ] || [ -z "$UNIFI_DB_RUNNING" ]; then
        return 1
    fi
    return 0
}

# Check if shim interface exists (only if SHIM_IP is configured)
check_shim() {
    if [ -z "$SHIM_IP" ]; then
        return 0  # No shim configured, skip check
    fi

    if ! ip link show unifi-shim &>/dev/null; then
        return 1
    fi

    # Check if shim is UP
    if ! ip link show unifi-shim | grep -q "state UP"; then
        return 1
    fi

    return 0
}

# Check if container has macvlan interface (eth1)
check_container_network() {
    if [ "$IS_VLAN" = "true" ]; then
        # For VLAN deployments, check routing-fixer container
        ETH1_EXISTS=$(docker exec unifi-routing-fixer ip link show eth1 2>/dev/null)
    else
        # For native LAN, check unifi container directly
        ETH1_EXISTS=$(docker exec unifi ip link show 2>/dev/null | grep -E "eth[0-9]@.*br" || true)
    fi

    if [ -z "$ETH1_EXISTS" ]; then
        return 1
    fi
    return 0
}

# Check if controller is responding on port 8443
check_controller_health() {
    # Check if UniFi is listening on port 8443 inside the container
    # Use routing-fixer container since it shares network namespace with unifi
    if docker exec unifi-routing-fixer netstat -tln 2>/dev/null | grep -q ":8443 "; then
        return 0
    fi

    # If netstat fails, controller might still be starting up
    # Check if Java process is running as a secondary indicator
    if docker exec unifi ps aux 2>/dev/null | grep -q "[j]ava.*ace.jar"; then
        # Java is running, might just be initializing - give it benefit of the doubt
        return 0
    fi

    return 1
}

# Recreate shim interface
recreate_shim() {
    if [ -z "$SHIM_IP" ]; then
        return 0  # No shim configured
    fi

    log "Recreating shim interface..."

    # Remove old shim if exists
    ip link delete unifi-shim 2>/dev/null || true

    # Create new shim
    ip link add unifi-shim link ${PARENT_INTERFACE} type macvlan mode bridge 2>/dev/null || true
    ip addr add ${SHIM_IP}/32 dev unifi-shim 2>/dev/null || true
    ip link set unifi-shim up 2>/dev/null || true
    ip route add ${CONTROLLER_IP}/32 dev unifi-shim 2>/dev/null || true
    ip route add ${CONTROLLER_IP}/32 dev unifi-shim table lan_routable 2>/dev/null || true

    log "Shim interface recreated"
}

# Full recovery: restart containers and networks
full_recovery() {
    log "========================================"
    log "STARTING FULL RECOVERY"
    log "========================================"

    cd "$COMPOSE_DIR" || return 1

    # Stop containers
    log "Stopping containers..."
    docker-compose down 2>&1 | tee -a "$LOG_FILE"

    # Prune orphaned networks
    log "Pruning orphaned networks..."
    docker network prune -f 2>&1 | tee -a "$LOG_FILE"

    # Wait a moment for cleanup
    sleep 2

    # Start containers
    log "Starting containers..."
    docker-compose up -d 2>&1 | tee -a "$LOG_FILE"

    # Wait for containers to initialize (UniFi takes 2-3 minutes to fully start)
    log "Waiting for containers to initialize (2 minutes)..."
    sleep 120

    # Recreate shim
    recreate_shim

    # Restore VLAN routing rules if needed
    if [ "$IS_VLAN" = "true" ]; then
        log "Restoring VLAN routing rules..."
        ip rule add from ${NETWORK_BASE}/${NETWORK_CIDR} lookup lan_routable priority 5002 2>/dev/null || true
    fi

    log "Full recovery completed"
    log "========================================"
}

# Main monitoring loop
monitor() {
    rotate_log

    # Check 1: Are containers running?
    if ! check_containers; then
        log "WARNING: Containers not running. Starting containers..."
        cd "$COMPOSE_DIR"
        docker-compose up -d 2>&1 | tee -a "$LOG_FILE"
        sleep 10
        recreate_shim
        return
    fi

    # Check 2: Does shim exist?
    if ! check_shim; then
        log "WARNING: Shim interface missing. Recreating..."
        recreate_shim
    fi

    # Check 3: Does container have macvlan network?
    if ! check_container_network; then
        log "ERROR: Container missing macvlan interface (eth1). Triggering full recovery..."
        full_recovery
        return
    fi

    # Check 4: Is controller responding?
    # Note: Only trigger recovery if controller is consistently down
    # Controller startup can take 2-3 minutes, so be patient
    if ! check_controller_health; then
        # Controller not responding - but could be starting up
        # Check if it's been a reasonable amount of time since last recovery
        LAST_RECOVERY_FILE="/tmp/unifi-monitor-last-recovery"
        if [ -f "$LAST_RECOVERY_FILE" ]; then
            LAST_RECOVERY=$(cat "$LAST_RECOVERY_FILE")
            CURRENT_TIME=$(date +%s)
            TIME_SINCE_RECOVERY=$((CURRENT_TIME - LAST_RECOVERY))

            # Only trigger recovery if it's been more than 5 minutes since last recovery
            if [ $TIME_SINCE_RECOVERY -lt 300 ]; then
                log "WARNING: Controller not responding, but recovery was recent ($TIME_SINCE_RECOVERY seconds ago). Giving it more time..."
                return
            fi
        fi

        log "ERROR: Controller not responding on port 8443. Triggering full recovery..."
        echo $(date +%s) > "$LAST_RECOVERY_FILE"
        full_recovery
        return
    fi

    # All checks passed - system healthy
    # Only log once per hour to avoid log spam
    CURRENT_MINUTE=$(date '+%M')
    if [ "$CURRENT_MINUTE" = "00" ]; then
        log "System healthy - all checks passed"
    fi
}

# Run monitor in loop
while true; do
    monitor
    sleep 60
done
