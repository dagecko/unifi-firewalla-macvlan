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

# Check for existing installation
echo -e "${YELLOW}Checking for existing installation...${NC}"
EXISTING_INSTALL=false

if [ -d /home/pi/.firewalla/run/docker/unifi ] || \
   [ -d /data/unifi ] || \
   [ -d /data/unifi-db ] || \
   sudo docker ps -a | grep -q "unifi\|unifi-db" || \
   sudo docker network ls | grep -q "unifi"; then
    EXISTING_INSTALL=true
    echo -e "${YELLOW}⚠ Existing UniFi installation detected!${NC}"
    echo ""
    echo "Found:"
    [ -d /home/pi/.firewalla/run/docker/unifi ] && echo "  - Configuration files"
    [ -d /data/unifi ] && echo "  - UniFi data directory"
    [ -d /data/unifi-db ] && echo "  - MongoDB data directory"
    sudo docker ps -a | grep -q "unifi\|unifi-db" && echo "  - Docker containers"
    sudo docker network ls | grep -q "unifi" && echo "  - Docker networks"
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo "  1. Clean install (removes ALL existing data and containers)"
    echo "  2. Cancel and run uninstall script manually"
    echo "  3. Continue anyway (may cause conflicts)"
    echo ""
    read -p "Choose option [1/2/3]: " INSTALL_OPTION

    case $INSTALL_OPTION in
        1)
            echo ""
            echo -e "${RED}WARNING: This will delete all existing UniFi configuration and data!${NC}"
            read -p "Type 'DELETE' to confirm: " CONFIRM_DELETE
            if [ "$CONFIRM_DELETE" != "DELETE" ]; then
                echo "Installation cancelled."
                exit 0
            fi

            echo ""
            echo -e "${YELLOW}Cleaning up existing installation...${NC}"

            # Stop containers and remove volumes
            if [ -f /home/pi/.firewalla/run/docker/unifi/docker-compose.yaml ]; then
                cd /home/pi/.firewalla/run/docker/unifi
                sudo docker-compose down -v --remove-orphans 2>/dev/null || true
                sleep 2
            fi

            # Drop MongoDB user if container is running
            if sudo docker ps -q -f name=unifi-db 2>/dev/null | grep -q .; then
                echo -n "  Dropping MongoDB users... "
                sudo docker exec unifi-db mongo admin --quiet --eval "db.getSiblingDB('unifi').dropUser('unifi')" 2>/dev/null || true
                echo -e "${GREEN}✓${NC}"
            fi

            # Force stop and remove any remaining containers
            sudo docker stop unifi unifi-db 2>/dev/null || true
            sudo docker rm -f unifi unifi-db 2>/dev/null || true

            # Wait for containers to fully release filesystem locks
            sleep 3

            # Remove any orphaned volumes
            sudo docker volume rm unifi_unifi-db-data 2>/dev/null || true
            sudo docker volume prune -f 2>/dev/null || true

            # Remove MongoDB image to force fresh pull
            sudo docker rmi mongo:4.4 2>/dev/null || true

            # Remove networks
            sudo docker network rm unifi_unifi-internal unifi_unifi-net 2>/dev/null || true

            # Remove shim
            sudo ip link delete unifi-shim 2>/dev/null || true

            # Remove data directories - force complete deletion
            echo -n "  Removing data directories... "
            sudo rm -rf /data/unifi/* /data/unifi/.* 2>/dev/null || true
            sudo rm -rf /data/unifi-db/* /data/unifi-db/.* 2>/dev/null || true
            sudo rm -rf /data/unifi /data/unifi-db

            # Recreate empty directories
            sudo mkdir -p /data/unifi
            sudo mkdir -p /data/unifi-db

            # Verify directories are empty
            if [ "$(sudo ls -A /data/unifi-db 2>/dev/null)" ]; then
                echo -e "${RED}✗ Failed to clean MongoDB directory${NC}"
                echo "Please manually remove: sudo rm -rf /data/unifi-db/*"
                exit 1
            fi
            if [ "$(sudo ls -A /data/unifi 2>/dev/null)" ]; then
                echo -e "${RED}✗ Failed to clean UniFi directory${NC}"
                echo "Please manually remove: sudo rm -rf /data/unifi/*"
                exit 1
            fi
            echo -e "${GREEN}✓${NC}"

            # Remove config files
            sudo rm -rf /home/pi/.firewalla/run/docker/unifi
            sudo rm -f /home/pi/.firewalla/config/post_main.d/start_unifi.sh

            echo -e "${GREEN}✓ Cleanup complete - MongoDB directory is empty${NC}"
            echo ""
            ;;
        2)
            echo ""
            echo "Please run the uninstall script first:"
            echo "  curl -sL \"https://raw.githubusercontent.com/dagecko/unifi-firewalla-macvlan/main/uninstall.sh\" -o /tmp/uninstall.sh"
            echo "  bash /tmp/uninstall.sh"
            exit 0
            ;;
        3)
            echo ""
            echo -e "${YELLOW}⚠ Continuing with existing installation present...${NC}"
            echo ""
            ;;
        *)
            echo "Invalid option. Installation cancelled."
            exit 1
            ;;
    esac
else
    echo -e "${GREEN}✓ No existing installation found${NC}"
fi
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

# Detect available networks on Firewalla
echo "Detecting available networks..."
echo ""
echo -e "${YELLOW}Available Networks on Firewalla:${NC}"
ip -4 addr show | grep -E "^[0-9]+: |inet " | sed 'N;s/\n/ /' | awk '{
    if ($2 ~ /:$/) {
        iface = substr($2, 1, length($2)-1);
        getline;
        if ($1 == "inet") {
            split($2, addr, "/");
            split(addr[1], octets, ".");
            network = octets[1] "." octets[2] "." octets[3] ".0/" addr[2];
            printf "  %-10s %-18s %s\n", iface, addr[1], network;
        }
    }
}'

echo ""
echo -e "${YELLOW}Network Selection${NC}"
echo "You can use an existing network or specify a custom one."
echo ""

# Get br0 IP as default suggestion
DETECTED_IP=$(ip addr show br0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || echo "")
DETECTED_CIDR=$(ip addr show br0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f2 || echo "24")

if [ -z "$DETECTED_IP" ]; then
    echo -e "${RED}Error: Could not detect IP address on br0 interface.${NC}"
    exit 1
fi

# Extract network prefix and calculate subnet
IFS='.' read -r o1 o2 o3 o4 <<< "$DETECTED_IP"
DEFAULT_NETWORK="${o1}.${o2}.${o3}.0/${DETECTED_CIDR}"
DEFAULT_GATEWAY="${DETECTED_IP}"

echo -e "Default network (br0): ${GREEN}${DEFAULT_NETWORK}${NC}"
echo -e "Default gateway: ${GREEN}${DEFAULT_GATEWAY}${NC}"
echo ""

# Network selection
read -p "Use a different network? (y/N): " -n 1 -r USE_CUSTOM_NETWORK
echo
if [[ $USE_CUSTOM_NETWORK =~ ^[Yy]$ ]]; then
    while true; do
        read -p "Enter network (e.g., 192.168.50.0/24): " CUSTOM_NETWORK
        if [[ $CUSTOM_NETWORK =~ ^[0-9]+\.[0-9]+\.[0-9]+\.0/[0-9]+$ ]]; then
            NETWORK_CIDR="${CUSTOM_NETWORK#*/}"
            NETWORK_BASE="${CUSTOM_NETWORK%/*}"
            IFS='.' read -r n1 n2 n3 n4 <<< "$NETWORK_BASE"
            NETWORK_PREFIX="${n1}.${n2}.${n3}"

            read -p "Enter gateway IP for this network (e.g., ${NETWORK_PREFIX}.1): " CUSTOM_GATEWAY
            if [[ $CUSTOM_GATEWAY =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                GATEWAY_IP="$CUSTOM_GATEWAY"
                break
            else
                echo -e "${RED}Invalid gateway IP format. Please try again.${NC}"
            fi
        else
            echo -e "${RED}Invalid network format. Use format: 192.168.1.0/24${NC}"
        fi
    done
else
    NETWORK_CIDR="$DETECTED_CIDR"
    NETWORK_BASE="${o1}.${o2}.${o3}.0"
    NETWORK_PREFIX="${o1}.${o2}.${o3}"
    GATEWAY_IP="$DEFAULT_GATEWAY"
fi

echo ""
echo -e "${YELLOW}Selected Network Configuration:${NC}"
echo -e "  Network:  ${GREEN}${NETWORK_BASE}/${NETWORK_CIDR}${NC}"
echo -e "  Gateway:  ${GREEN}${GATEWAY_IP}${NC}"
echo ""

# Configuration prompts
echo -e "${YELLOW}Container Configuration${NC}"
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
echo -e "  Network:              ${NETWORK_BASE}/${NETWORK_CIDR}"
echo -e "  Gateway:              ${GATEWAY_IP}"
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

# Clean up any leftover networks from previous failed installations
echo -n "Checking for leftover networks... "
if sudo docker network ls | grep -q "unifi_unifi-internal\|unifi_unifi-net"; then
    sudo docker network rm unifi_unifi-internal 2>/dev/null || true
    sudo docker network rm unifi_unifi-net 2>/dev/null || true
    echo -e "${GREEN}✓ Cleaned${NC}"
else
    echo -e "${GREEN}✓ None found${NC}"
fi

# Create directories
echo -n "Creating directories... "
sudo mkdir -p /data/unifi
sudo mkdir -p /data/unifi-db
sudo mkdir -p /home/pi/.firewalla/run/docker/unifi
sudo mkdir -p /home/pi/.firewalla/config/post_main.d
echo -e "${GREEN}✓${NC}"

# Ensure MongoDB data directory is completely empty for init script to run
echo -n "Ensuring clean MongoDB directory... "
if [ "$(sudo ls -A /data/unifi-db 2>/dev/null)" ]; then
    echo -e "${RED}✗ MongoDB directory not empty!${NC}"
    echo "The /data/unifi-db directory must be completely empty for initialization."
    exit 1
fi
echo -e "${GREEN}✓${NC}"

# Create MongoDB init script in a separate location
echo -n "Creating MongoDB init script... "
sudo bash -c "cat > /home/pi/.firewalla/run/docker/unifi/init-mongo.js" << 'MONGOEOF'
db.getSiblingDB("unifi").createUser({
  user: "unifi",
  pwd: "MONGO_PASSWORD_PLACEHOLDER",
  roles: [{ role: "readWrite", db: "unifi" }]
});
MONGOEOF
# Replace placeholder with actual password - escape special characters for sed
ESCAPED_PASSWORD=$(printf '%s\n' "$MONGO_PASSWORD" | sed 's/[&/\]/\\&/g')
sudo sed -i "s|MONGO_PASSWORD_PLACEHOLDER|${ESCAPED_PASSWORD}|g" /home/pi/.firewalla/run/docker/unifi/init-mongo.js
echo -e "${GREEN}✓${NC}"

# Create .env file with URL-encoded password per LinuxServer.io documentation
# TODO: Future enhancement - support AWS Secrets Manager and other secret stores
echo -n "Creating environment file... "
# URL encode the password - LinuxServer.io requires special characters to be URL encoded
URL_ENCODED_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${MONGO_PASSWORD}', safe=''))" 2>/dev/null || \
                   printf '%s' "${MONGO_PASSWORD}" | sed 's/!/%21/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/\^/%5E/g; s/\*/%2A/g')
sudo bash -c "cat > /home/pi/.firewalla/run/docker/unifi/.env" << ENVEOF
MONGO_PASSWORD=${URL_ENCODED_PASS}
ENVEOF
sudo chmod 600 /home/pi/.firewalla/run/docker/unifi/.env
echo -e "${GREEN}✓${NC}"

# Create docker-compose.yaml with hybrid networking
echo -n "Creating docker-compose.yaml... "
sudo bash -c "cat > /home/pi/.firewalla/run/docker/unifi/docker-compose.yaml" << 'EOF'
version: "3.8"

services:
  unifi-db:
    image: docker.io/mongo:4.4
    container_name: unifi-db
    environment:
      - TZ=TZ_SETTING_PLACEHOLDER
    volumes:
      - /data/unifi-db:/data/db
      - /home/pi/.firewalla/run/docker/unifi/init-mongo.js:/docker-entrypoint-initdb.d/init-mongo.js:ro
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
      - TZ=TZ_SETTING_PLACEHOLDER
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
        ipv4_address: CONTROLLER_IP_PLACEHOLDER

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
        - subnet: NETWORK_BASE_PLACEHOLDER/NETWORK_CIDR_PLACEHOLDER
          gateway: GATEWAY_IP_PLACEHOLDER
          ip_range: CONTROLLER_IP_PLACEHOLDERIP_RANGE_CIDR_PLACEHOLDER
EOF
# Replace all placeholders with actual values - password comes from .env file
sudo sed -i "s|TZ_SETTING_PLACEHOLDER|${TZ_SETTING}|g" /home/pi/.firewalla/run/docker/unifi/docker-compose.yaml
sudo sed -i "s|CONTROLLER_IP_PLACEHOLDER|${CONTROLLER_IP}|g" /home/pi/.firewalla/run/docker/unifi/docker-compose.yaml
sudo sed -i "s|NETWORK_BASE_PLACEHOLDER|${NETWORK_BASE}|g" /home/pi/.firewalla/run/docker/unifi/docker-compose.yaml
sudo sed -i "s|NETWORK_CIDR_PLACEHOLDER|${NETWORK_CIDR}|g" /home/pi/.firewalla/run/docker/unifi/docker-compose.yaml
sudo sed -i "s|GATEWAY_IP_PLACEHOLDER|${GATEWAY_IP}|g" /home/pi/.firewalla/run/docker/unifi/docker-compose.yaml
sudo sed -i "s|IP_RANGE_CIDR_PLACEHOLDER|${IP_RANGE_CIDR}|g" /home/pi/.firewalla/run/docker/unifi/docker-compose.yaml
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
NETWORK_BASE=${NETWORK_BASE}
NETWORK_CIDR=${NETWORK_CIDR}
NETWORK_PREFIX=${NETWORK_PREFIX}
TZ_SETTING=${TZ_SETTING}
SHIM_IP=${SHIM_IP}
IP_RANGE_CIDR=${IP_RANGE_CIDR}
IP_COUNT=${IP_COUNT}
EOF
echo -e "${GREEN}✓${NC}"

# Pull images and start containers
echo ""
echo -e "${YELLOW}Pulling Docker images and starting containers (this may take several minutes)...${NC}"
cd /home/pi/.firewalla/run/docker/unifi
sudo docker-compose up -d --pull always

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
echo -e "${GREEN}║                   Installation Complete!                    ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "Access the UniFi Controller at:"
echo -e "  ${GREEN}https://${CONTROLLER_IP}:8443${NC}"
echo ""
echo -e "${YELLOW}Note:${NC} The controller may take ${YELLOW}2-5 minutes${NC} to fully start."
echo -e "      You will see a certificate warning - this is expected."
echo ""
echo -e "${GREEN}Architecture:${NC}"
echo -e "  • UniFi Controller: ${CONTROLLER_IP} (on management network)"
echo -e "  • MongoDB: Internal Docker network only (not network-accessible)"
echo -e "  • Security: MongoDB is isolated from the network"
echo ""
echo -e "${GREEN}Access Methods:${NC}"
echo -e "  • From external devices (laptop/phone):"
echo -e "    ${GREEN}curl -k https://${CONTROLLER_IP}:8443${NC}"
echo -e "    (Direct access works normally)"
echo ""
if [ -z "$SHIM_IP" ]; then
    echo -e "  • From Firewalla host:"
    echo -e "    ${YELLOW}Not accessible${NC} (macvlan limitation)"
    echo -e "    Re-run installer with shim enabled for host access"
    echo ""
else
    echo -e "  • From Firewalla host (shim enabled):"
    echo -e "    ${GREEN}curl -k --interface unifi-shim https://${CONTROLLER_IP}:8443${NC}"
    echo -e "    Note: Must use '--interface unifi-shim' flag"
    echo -e "    See advanced.md for health check scripts"
    echo ""
fi
echo -e "To restore from a UDM/Cloud Key backup:"
echo -e "  1. Open https://${CONTROLLER_IP}:8443"
echo -e "  2. Choose 'Restore from backup' during setup"
echo -e "  3. Upload your .unf backup file"
echo ""
