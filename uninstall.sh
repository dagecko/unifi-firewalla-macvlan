#!/bin/bash

# UniFi Controller on Firewalla Gold Pro - Macvlan Uninstall Script
# https://github.com/dagecko/unifi-firewalla-macvlan

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  UniFi Controller Uninstaller for Firewalla (Macvlan Edition) ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${YELLOW}Warning: This will remove the UniFi Controller and ALL related data!${NC}"
echo ""
echo "The following will be deleted:"
echo "  - Docker containers (unifi, unifi-db)"
echo "  - Docker images"
echo "  - /data/unifi (controller data)"
echo "  - /data/unifi-db (database)"
echo "  - /home/pi/.firewalla/run/docker/unifi/"
echo "  - /home/pi/.firewalla/config/post_main.d/start_unifi.sh"
echo ""

read -p "Are you sure you want to continue? (yes/N): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""
echo -e "${YELLOW}Stopping containers...${NC}"

# Stop and remove containers
if [ -f /home/pi/.firewalla/run/docker/unifi/docker-compose.yaml ]; then
    cd /home/pi/.firewalla/run/docker/unifi
    sudo docker-compose down -v 2>/dev/null && echo -e "${GREEN}✓ Containers stopped${NC}" || echo -e "${YELLOW}⚠ No compose containers found${NC}"
fi

# Remove any remaining containers
sudo docker stop unifi 2>/dev/null && echo -e "${GREEN}✓ unifi container stopped${NC}" || true
sudo docker stop unifi-db 2>/dev/null && echo -e "${GREEN}✓ unifi-db container stopped${NC}" || true
sudo docker rm unifi 2>/dev/null && echo -e "${GREEN}✓ unifi container removed${NC}" || true
sudo docker rm unifi-db 2>/dev/null && echo -e "${GREEN}✓ unifi-db container removed${NC}" || true

echo ""
echo -e "${YELLOW}Removing Docker images...${NC}"
sudo docker rmi lscr.io/linuxserver/unifi-network-application:latest 2>/dev/null && echo -e "${GREEN}✓ UniFi image removed${NC}" || echo -e "${YELLOW}⚠ UniFi image not found${NC}"
sudo docker rmi mongo:4.4 2>/dev/null && echo -e "${GREEN}✓ MongoDB image removed${NC}" || echo -e "${YELLOW}⚠ MongoDB image not found${NC}"

echo ""
echo -e "${YELLOW}Removing Docker networks...${NC}"
sudo docker network rm unifi_unifi-internal 2>/dev/null && echo -e "${GREEN}✓ unifi_unifi-internal network removed${NC}" || echo -e "${YELLOW}⚠ unifi_unifi-internal network not found${NC}"
sudo docker network rm unifi_unifi-net 2>/dev/null && echo -e "${GREEN}✓ unifi_unifi-net network removed${NC}" || echo -e "${YELLOW}⚠ unifi_unifi-net network not found${NC}"

echo ""
echo -e "${YELLOW}Removing shim interface, routes, and policy rules...${NC}"
# Remove all routes using unifi-shim from main table
while read -r route; do
    [ -n "$route" ] && sudo ip route del $route 2>/dev/null || true
done < <(ip route | grep "dev unifi-shim")
# Remove all routes using unifi-shim from lan_routable table
while read -r route; do
    [ -n "$route" ] && sudo ip route del $route table lan_routable 2>/dev/null || true
done < <(ip route show table lan_routable | grep "dev unifi-shim")
# Remove policy routing rules for VLAN networks (priority 5002)
while read -r rule; do
    RULE_NUM=$(echo "$rule" | awk '{print $1}' | tr -d ':')
    [ -n "$RULE_NUM" ] && sudo ip rule del pref $RULE_NUM 2>/dev/null || true
done < <(ip rule list | grep "lookup lan_routable" | grep "5002:")
# Remove policy routing rules for container return traffic (priority 500)
while read -r rule; do
    RULE_NUM=$(echo "$rule" | awk '{print $1}' | tr -d ':')
    [ -n "$RULE_NUM" ] && sudo ip rule del pref $RULE_NUM 2>/dev/null || true
done < <(ip rule list | grep "lookup main" | grep "500:")
# Remove default route from lan_routable table if it was added for VLAN
# (Only remove if it's the exact route we added - check for eth0)
DEFAULT_VIA_ETH0=$(ip route show table lan_routable | grep "^default via .* dev eth0$")
if [ -n "$DEFAULT_VIA_ETH0" ]; then
    sudo ip route del default table lan_routable 2>/dev/null && echo -e "${GREEN}✓ VLAN default route removed${NC}" || true
fi
sudo ip link delete unifi-shim 2>/dev/null && echo -e "${GREEN}✓ Shim interface, routes, and rules removed${NC}" || echo -e "${YELLOW}⚠ Shim interface not found${NC}"

echo ""
echo -e "${YELLOW}Removing data directories...${NC}"
if [ -d /data/unifi ] || [ -d /data/unifi-db ]; then
    echo -e "${YELLOW}Note: This will delete all UniFi configuration and database!${NC}"
    read -p "Delete all data? (yes/N): " DELETE_DATA
    if [ "$DELETE_DATA" = "yes" ]; then
        sudo rm -rf /data/unifi 2>/dev/null && echo -e "${GREEN}✓ /data/unifi removed${NC}" || true
        sudo rm -rf /data/unifi-db 2>/dev/null && echo -e "${GREEN}✓ /data/unifi-db removed${NC}" || true
    else
        echo -e "${YELLOW}⚠ Data directories preserved${NC}"
    fi
else
    echo -e "${YELLOW}⚠ No data directories found${NC}"
fi

echo ""
echo -e "${YELLOW}Removing configuration files...${NC}"
sudo rm -rf /home/pi/.firewalla/run/docker/unifi 2>/dev/null && echo -e "${GREEN}✓ Docker config removed${NC}" || echo -e "${YELLOW}⚠ Docker config not found${NC}"
sudo rm -f /home/pi/.firewalla/config/post_main.d/start_unifi.sh 2>/dev/null && echo -e "${GREEN}✓ Startup script removed${NC}" || echo -e "${YELLOW}⚠ Startup script not found${NC}"

echo ""
echo -e "${YELLOW}Cleaning up Docker...${NC}"
sudo docker system prune -f 2>/dev/null && echo -e "${GREEN}✓ Docker cleanup complete${NC}"

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    Uninstall Complete!                         ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "All UniFi Controller components have been removed."
echo "You can reinstall at any time by running the install script."
echo ""
