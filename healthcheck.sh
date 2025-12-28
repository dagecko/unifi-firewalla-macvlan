#!/bin/bash

# UniFi Controller Health Check for Firewalla
# https://github.com/dagecko/unifi-firewalla-macvlan
#
# Requires shim interface to be enabled (see advanced.md)
# Returns 0 if healthy, 1 if unhealthy
#
# Usage: ./healthcheck.sh [--verbose]

VERBOSE=false
if [ "$1" = "--verbose" ] || [ "$1" = "-v" ]; then
    VERBOSE=true
fi

# Load config if available
CONFIG_FILE="/data/unifi/install-config.txt"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Defaults if config not found
CONTROLLER_IP=${CONTROLLER_IP:-"192.168.240.2"}
MONGO_IP=${MONGO_IP:-"192.168.240.3"}

HEALTHY=true
MESSAGES=()

# Check if containers are running
UNIFI_RUNNING=$(docker inspect -f '{{.State.Running}}' unifi 2>/dev/null)
MONGO_RUNNING=$(docker inspect -f '{{.State.Running}}' unifi-db 2>/dev/null)

if [ "$UNIFI_RUNNING" != "true" ]; then
    HEALTHY=false
    MESSAGES+=("CRITICAL: UniFi container not running")
else
    MESSAGES+=("OK: UniFi container running")
fi

if [ "$MONGO_RUNNING" != "true" ]; then
    HEALTHY=false
    MESSAGES+=("CRITICAL: MongoDB container not running")
else
    MESSAGES+=("OK: MongoDB container running")
fi

# Check container health status
UNIFI_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' unifi 2>/dev/null || echo "none")
if [ "$UNIFI_HEALTH" = "healthy" ]; then
    MESSAGES+=("OK: UniFi health status: healthy")
elif [ "$UNIFI_HEALTH" = "unhealthy" ]; then
    HEALTHY=false
    MESSAGES+=("CRITICAL: UniFi health status: unhealthy")
elif [ "$UNIFI_HEALTH" != "none" ]; then
    MESSAGES+=("INFO: UniFi health status: $UNIFI_HEALTH")
fi

# Check if shim interface exists
if ip link show unifi-shim &>/dev/null; then
    MESSAGES+=("OK: Shim interface exists")
    
    # Check if controller responds via shim
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k --max-time 10 "https://${CONTROLLER_IP}:8443" 2>/dev/null)
    
    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ]; then
        MESSAGES+=("OK: Controller responding (HTTP $HTTP_CODE)")
    elif [ "$HTTP_CODE" = "000" ]; then
        HEALTHY=false
        MESSAGES+=("CRITICAL: Controller not responding (connection failed)")
    else
        MESSAGES+=("WARNING: Controller returned HTTP $HTTP_CODE")
    fi
else
    MESSAGES+=("INFO: Shim interface not configured (skipping HTTP check)")
fi

# Check disk space for /data
DISK_USAGE=$(df /data 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
if [ -n "$DISK_USAGE" ]; then
    if [ "$DISK_USAGE" -gt 90 ]; then
        HEALTHY=false
        MESSAGES+=("CRITICAL: Disk usage at ${DISK_USAGE}%")
    elif [ "$DISK_USAGE" -gt 80 ]; then
        MESSAGES+=("WARNING: Disk usage at ${DISK_USAGE}%")
    else
        MESSAGES+=("OK: Disk usage at ${DISK_USAGE}%")
    fi
fi

# Check memory usage of containers
UNIFI_MEM=$(docker stats --no-stream --format "{{.MemUsage}}" unifi 2>/dev/null | awk '{print $1}')
if [ -n "$UNIFI_MEM" ]; then
    MESSAGES+=("INFO: UniFi memory usage: $UNIFI_MEM")
fi

# Output
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if [ "$VERBOSE" = true ]; then
    echo "[$TIMESTAMP] UniFi Controller Health Check"
    echo "─────────────────────────────────────────"
    for msg in "${MESSAGES[@]}"; do
        echo "  $msg"
    done
    echo "─────────────────────────────────────────"
fi

if [ "$HEALTHY" = true ]; then
    echo "[$TIMESTAMP] HEALTHY"
    exit 0
else
    echo "[$TIMESTAMP] UNHEALTHY"
    if [ "$VERBOSE" = false ]; then
        for msg in "${MESSAGES[@]}"; do
            if [[ "$msg" == CRITICAL* ]]; then
                echo "  $msg"
            fi
        done
    fi
    exit 1
fi
