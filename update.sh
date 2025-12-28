#!/bin/bash

# UniFi Controller on Firewalla Gold Pro - Update Script
# https://github.com/dagecko/unifi-firewalla-macvlan

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║   UniFi Controller Updater for Firewalla (Macvlan Edition)    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

COMPOSE_DIR="/home/pi/.firewalla/run/docker/unifi"

if [ ! -f "$COMPOSE_DIR/docker-compose.yaml" ]; then
    echo -e "${YELLOW}Error: UniFi Controller does not appear to be installed.${NC}"
    echo "Expected docker-compose.yaml at: $COMPOSE_DIR"
    exit 1
fi

# Get current version info
echo -e "${YELLOW}Current container status:${NC}"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep -E "NAMES|unifi"
echo ""

read -p "Pull latest images and restart containers? (Y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Update cancelled."
    exit 0
fi

echo ""
echo -e "${YELLOW}Pulling latest images...${NC}"
cd "$COMPOSE_DIR"
sudo docker-compose pull

echo ""
echo -e "${YELLOW}Restarting containers...${NC}"
sudo docker-compose up -d

echo ""
echo -e "${YELLOW}Cleaning up old images...${NC}"
sudo docker system prune -f

echo ""
echo -e "${YELLOW}New container status:${NC}"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | grep -E "NAMES|unifi"

echo ""
echo -e "${GREEN}✓ Update complete!${NC}"
echo ""
echo "Note: The controller may take 2-3 minutes to fully restart."
echo "Check logs with: docker logs unifi"
echo ""
