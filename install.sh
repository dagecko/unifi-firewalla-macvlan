#!/bin/bash

# UniFi Controller on Firewalla Gold Pro - Macvlan Install Script
# https://github.com/dagecko/unifi-firewalla-macvlan

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  UniFi Controller Installer for Firewalla (Macvlan Edition)   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check if running as root or with sudo
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}Error: Do not run this script as root or with sudo.${NC}"
    echo "The script will prompt for sudo when needed."
    exit 1
fi

# Check if running on Firewalla
if [ ! -f /etc/firewalla-release ]; then
    echo -e "${RED}Error: This script is designed for Firewalla devices only.${NC}"
    exit 1
fi

# Pre-flight checks
echo -e "${YELLOW}Running pre-flight checks...${NC}"

# Check for Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed or not in PATH.${NC}"
    exit 1
fi

# Check if Docker service is running
if ! sudo systemctl is-active --quiet docker; then
    echo -e "${YELLOW}Docker service is not running. Starting Docker...${NC}"
    sudo systemctl start docker
    sleep 3
fi

# Check for docker-compose
if ! command -v docker-compose &> /dev/null; then
    echo -e "${RED}Error: docker-compose is not installed or not in PATH.${NC}"
    exit 1
fi

# Check if br0 interface exists
if ! ip link show br0 &> /dev/null; then
    echo -e "${RED}Error: br0 interface not found.${NC}"
    echo "Expected interface: br0"
    echo "Available interfaces:"
    ip -brief link show
    exit 1
fi

echo -e "${GREEN}✓ Pre-flight checks passed${NC}"
echo ""

# Check for Gold series
SERIES=""
if [ -f /etc/update-motd.d/00-header ]; then
    SERIES=$(/etc/update-motd.d/00-header 2>/dev/null | grep "Welcome to" | sed -e "s|Welcome to ||g" -e "s|FIREWALLA ||g" -e "s|\s[0-9].*$||g" || echo "")
fi

if [[ "$SERIES" == *"purple"* ]]; then
    echo -e "${YELLOW}Warning: Firewalla Purple detected. UniFi Controller may be too resource-intensive.${NC}"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo -e "${GREEN}Detected: Firewalla ${SERIES:-Gold}${NC}"
echo ""

# Detect network interface and current IP
echo "Detecting network configuration..."
DETECTED_IP=$(ip addr show br0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || echo "")

if [ -z "$DETECTED_IP" ]; then
    echo -e "${RED}Error: Could not detect IP address on br0 interface.${NC}"
    exit 1
fi

# Extract network prefix (e.g., 192.168.240 from 192.168.240.1)
NETWORK_PREFIX=$(echo "$DETECTED_IP" | cut -d. -f1-3)

echo -e "  Interface: ${GREEN}br0${NC}"
echo -e "  Firewalla IP: ${GREEN}${DETECTED_IP}${NC}"
echo -e "  Network: ${GREEN}${NETWORK_PREFIX}.0/24${NC}"
echo ""

# Configuration prompts
echo -e "${YELLOW}Configuration${NC}"
echo "─────────────────────────────────────────────────────────────────"

# Controller IP
DEFAULT_CONTROLLER_IP="${NETWORK_PREFIX}.2"
read -p "UniFi Controller IP [${DEFAULT_CONTROLLER_IP}]: " CONTROLLER_IP
CONTROLLER_IP=${CONTROLLER_IP:-$DEFAULT_CONTROLLER_IP}

# Additional IP addresses option
echo ""
echo -e "${YELLOW}Optional: Additional Container IPs${NC}"
echo "By default, only the UniFi Controller gets a network IP (MongoDB uses internal networking)."
echo "If you plan to add more containers to this macvlan network, specify how many IPs to reserve."
DEFAULT_IP_COUNT="1"
read -p "Number of IPs to reserve for containers [${DEFAULT_IP_COUNT}]: " IP_COUNT
IP_COUNT=${IP_COUNT:-$DEFAULT_IP_COUNT}

# Calculate IP range CIDR based on count
case $IP_COUNT in
    1) IP_RANGE_CIDR="/32" ;;
    2) IP_RANGE_CIDR="/31" ;;
    3|4) IP_RANGE_CIDR="/30" ;;
    5|6|7|8) IP_RANGE_CIDR="/29" ;;
    9|10|11|12|13|14|15|16) IP_RANGE_CIDR="/28" ;;
    *) IP_RANGE_CIDR="/27" ;;
esac

# MongoDB password
echo ""
echo -e "${YELLOW}MongoDB Configuration${NC}"
echo "Set a secure password for the MongoDB database (used internally by UniFi)."
while true; do
    read -sp "MongoDB password: " MONGO_PASSWORD
    echo
    if [ -z "$MONGO_PASSWORD" ]; then
        echo -e "${RED}Password cannot be empty. Please try again.${NC}"
        continue
    fi
    read -sp "Confirm password: " MONGO_PASSWORD_CONFIRM
    echo
    if [ "$MONGO_PASSWORD" = "$MONGO_PASSWORD_CONFIRM" ]; then
        break
    else
        echo -e "${RED}Passwords do not match. Please try again.${NC}"
    fi
done

# Timezone
echo ""
DEFAULT_TZ="America/New_York"
read -p "Timezone [${DEFAULT_TZ}]: " TZ_SETTING
TZ_SETTING=${TZ_SETTING:-$DEFAULT_TZ}

# Gateway (Firewalla IP)
GATEWAY_IP="$DETECTED_IP"

# Shim interface for host access
DEFAULT_SHIM_IP="${NETWORK_PREFIX}.254"
echo ""
echo -e "${YELLOW}Optional: Shim Interface${NC}"
echo "A shim interface allows Firewalla to communicate with the controller"
echo "(useful for health checks, API access, monitoring)."
read -p "Enable shim interface? (y/N): " -n 1 -r ENABLE_SHIM
echo
SHIM_IP=""
if [[ $ENABLE_SHIM =~ ^[Yy]$ ]]; then
    read -p "Shim interface IP [${DEFAULT_SHIM_IP}]: " SHIM_IP
    SHIM_IP=${SHIM_IP:-$DEFAULT_SHIM_IP}
fi

echo ""
echo -e "${YELLOW}Configuration Summary${NC}"
echo "─────────────────────────────────────────────────────────────────"
echo -e "  Network Interface:    br0"
echo -e "  Network:              ${NETWORK_PREFIX}.0/24"
echo -e "  Gateway (Firewalla):  ${GATEWAY_IP}"
echo -e "  UniFi Controller:     ${CONTROLLER_IP}"
echo -e "  MongoDB:              Internal Docker network (not exposed)"
echo -e "  Reserved IPs:         ${IP_COUNT} (${CONTROLLER_IP}${IP_RANGE_CIDR})"
echo -e "  Timezone:             ${TZ_SETTING}"
echo -e "  Data Directory:       /data/unifi"
if [ -n "$SHIM_IP" ]; then
    echo -e "  Shim Interface:       ${SHIM_IP} (enabled)"
else
    echo -e "  Shim Interface:       disabled"
fi
echo ""

read -p "Proceed with installation? (Y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

echo ""
echo -e "${GREEN}Starting installation...${NC}"

# Create directories
echo -n "Creating directories... "
sudo mkdir -p /data/unifi
sudo mkdir -p /data/unifi-db
sudo mkdir -p /home/pi/.firewalla/run/docker/unifi
sudo mkdir -p /home/pi/.firewalla/config/post_main.d
echo -e "${GREEN}✓${NC}"

# Create MongoDB init script
echo -n "Creating MongoDB init script... "
sudo bash -c "cat > /data/unifi-db/init-mongo.js" << MONGOEOF
db.getSiblingDB("unifi").createUser({
  user: "unifi",
  pwd: "$MONGO_PASSWORD",
  roles: [{ role: "readWrite", db: "unifi" }]
});
MONGOEOF
echo -e "${GREEN}✓${NC}"

# Create docker-compose.yaml with hybrid networking
echo -n "Creating docker-compose.yaml... "
sudo bash -c "cat > /home/pi/.firewalla/run/docker/unifi/docker-compose.yaml" << EOF
version: "3.8"

services:
  unifi-db:
    image: docker.io/mongo:4.4
    container_name: unifi-db
    environment:
      - TZ=${TZ_SETTING}
    volumes:
      - /data/unifi-db:/data/db
      - /data/unifi-db/init-mongo.js:/docker-entrypoint-initdb.d/init-mongo.js:ro
    restart: unless-stopped
    networks:
      - unifi-internal

  unifi:
    image: lscr.io/linuxserver/unifi-network-application:latest
    container_name: unifi
    depends_on:
      - unifi-db
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=${TZ_SETTING}
      - MONGO_USER=unifi
      - MONGO_PASS=${MONGO_PASSWORD}
      - MONGO_HOST=unifi-db
      - MONGO_PORT=27017
      - MONGO_DBNAME=unifi
    volumes:
      - /data/unifi:/config
    restart: unless-stopped
    networks:
      unifi-internal:
      unifi-net:
        ipv4_address: ${CONTROLLER_IP}

networks:
  unifi-internal:
    driver: bridge
    internal: false

  unifi-net:
    driver: macvlan
    driver_opts:
      parent: br0
    ipam:
      config:
        - subnet: ${NETWORK_PREFIX}.0/24
          gateway: ${GATEWAY_IP}
          ip_range: ${CONTROLLER_IP}${IP_RANGE_CIDR}
EOF
echo -e "${GREEN}✓${NC}"

# Create startup script for persistence
echo -n "Creating startup script... "
if [ -n "$SHIM_IP" ]; then
sudo bash -c "cat > /home/pi/.firewalla/config/post_main.d/start_unifi.sh" << EOF
#!/bin/bash
sudo systemctl start docker
sleep 5
cd /home/pi/.firewalla/run/docker/unifi
sudo docker-compose up -d

# Create shim interface for host access to containers
sleep 10
sudo ip link add unifi-shim link br0 type macvlan mode bridge 2>/dev/null || true
sudo ip addr add ${SHIM_IP}/32 dev unifi-shim 2>/dev/null || true
sudo ip link set unifi-shim up 2>/dev/null || true
sudo ip route add ${CONTROLLER_IP}/32 dev unifi-shim 2>/dev/null || true
EOF
else
sudo bash -c "cat > /home/pi/.firewalla/config/post_main.d/start_unifi.sh" << 'EOF'
#!/bin/bash
sudo systemctl start docker
sleep 5
cd /home/pi/.firewalla/run/docker/unifi
sudo docker-compose up -d
EOF
fi
sudo chmod +x /home/pi/.firewalla/config/post_main.d/start_unifi.sh
sudo chown pi:pi /home/pi/.firewalla/config/post_main.d/start_unifi.sh
echo -e "${GREEN}✓${NC}"

# Save configuration for reference
echo -n "Saving configuration... "
sudo bash -c "cat > /data/unifi/install-config.txt" << EOF
# UniFi Controller Installation Config
# Generated: $(date)
CONTROLLER_IP=${CONTROLLER_IP}
GATEWAY_IP=${GATEWAY_IP}
NETWORK_PREFIX=${NETWORK_PREFIX}
TZ_SETTING=${TZ_SETTING}
SHIM_IP=${SHIM_IP}
IP_RANGE_CIDR=${IP_RANGE_CIDR}
IP_COUNT=${IP_COUNT}
EOF
echo -e "${GREEN}✓${NC}"

# Pull images and start containers
echo ""
echo -e "${YELLOW}Pulling Docker images (this may take several minutes)...${NC}"
cd /home/pi/.firewalla/run/docker/unifi
sudo docker-compose pull

echo ""
echo -e "${YELLOW}Starting containers...${NC}"
sudo docker-compose up -d

# Wait for containers to start
echo ""
echo -n "Waiting for containers to initialize"
for i in {1..30}; do
    echo -n "."
    sleep 2
    UNIFI_STATUS=$(sudo docker inspect -f '{{.State.Running}}' unifi 2>/dev/null || echo "false")
    MONGO_STATUS=$(sudo docker inspect -f '{{.State.Running}}' unifi-db 2>/dev/null || echo "false")
    if [ "$UNIFI_STATUS" = "true" ] && [ "$MONGO_STATUS" = "true" ]; then
        break
    fi
done
echo ""

# Check final status
echo ""
echo -e "${YELLOW}Container Status${NC}"
echo "─────────────────────────────────────────────────────────────────"
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "NAMES|unifi"

# Set up shim interface if enabled
if [ -n "$SHIM_IP" ]; then
    echo ""
    echo -n "Setting up shim interface... "
    sudo ip link add unifi-shim link br0 type macvlan mode bridge 2>/dev/null || true
    sudo ip addr add ${SHIM_IP}/32 dev unifi-shim 2>/dev/null || true
    sudo ip link set unifi-shim up 2>/dev/null || true
    sudo ip route add ${CONTROLLER_IP}/32 dev unifi-shim 2>/dev/null || true
    echo -e "${GREEN}✓${NC}"
fi

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    Installation Complete!                      ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Access the UniFi Controller at:"
echo -e "  ${GREEN}https://${CONTROLLER_IP}:8443${NC}"
echo ""
echo -e "${YELLOW}Note:${NC} The controller may take 2-3 minutes to fully start."
echo -e "      You will see a certificate warning - this is expected."
echo ""
echo -e "${GREEN}Architecture:${NC}"
echo -e "  • UniFi Controller: ${CONTROLLER_IP} (on management network)"
echo -e "  • MongoDB: Internal Docker network only (not network-accessible)"
echo -e "  • Security: MongoDB is isolated from the network"
echo ""
if [ -z "$SHIM_IP" ]; then
    echo -e "${YELLOW}Important:${NC} Due to macvlan networking, you cannot access the"
    echo -e "           controller directly from the Firewalla (${GATEWAY_IP})."
    echo -e "           Use another device on the ${NETWORK_PREFIX}.0/24 network."
    echo -e "           (Re-run installer with shim enabled for host access)"
    echo ""
fi
echo -e "To restore from a UDM/Cloud Key backup:"
echo -e "  1. Open https://${CONTROLLER_IP}:8443"
echo -e "  2. Choose 'Restore from backup' during setup"
echo -e "  3. Upload your .unf backup file"
echo ""
if [ -n "$SHIM_IP" ]; then
    echo -e "${GREEN}Shim interface enabled!${NC}"
    echo -e "  You can access the controller from Firewalla via ${SHIM_IP}"
    echo -e "  Test with: curl -k https://${CONTROLLER_IP}:8443"
    echo -e "  See advanced.md for health check scripts."
    echo ""
fi
