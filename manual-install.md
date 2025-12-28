# Manual Installation Guide

This guide provides step-by-step instructions for manually installing UniFi Controller on Firewalla Gold series using macvlan networking.

## Prerequisites

- SSH access to your Firewalla
- Management network configured (e.g., 192.168.240.0/24)
- One available IP address for the UniFi Controller

## Step 1: Plan Your IP Addresses

| Device | IP Address | Network |
|--------|------------|---------|
| Firewalla | 192.168.240.1 | Management Network |
| UniFi Controller | 192.168.240.2 | Management Network (macvlan) |
| MongoDB | N/A | Internal Docker Network (isolated) |

**Note:** MongoDB runs on an internal Docker network and is not exposed to your management network for security.

## Step 2: Create Directories

```bash
mkdir -p /data/unifi
mkdir -p /data/unifi-db
mkdir -p /home/pi/.firewalla/run/docker/unifi
mkdir -p /home/pi/.firewalla/config/post_main.d
```

## Step 3: Create MongoDB Init Script

```bash
cat > /data/unifi-db/init-mongo.js << 'EOF'
db.getSiblingDB("unifi").createUser({
  user: "unifi",
  pwd: "YOUR_SECURE_PASSWORD_HERE",
  roles: [{ role: "readWrite", db: "unifi" }]
});
EOF
```

**WARNING:** Replace `YOUR_SECURE_PASSWORD_HERE` with a strong, unique password.

## Step 4: Create Docker Compose File

Create `/home/pi/.firewalla/run/docker/unifi/docker-compose.yaml`:

```yaml
version: "3.8"

services:
  unifi-db:
    image: docker.io/mongo:4.4
    container_name: unifi-db
    environment:
      - TZ=America/New_York
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
      - TZ=America/New_York
      - MONGO_USER=unifi
      - MONGO_PASS=YOUR_SECURE_PASSWORD_HERE
      - MONGO_HOST=unifi-db
      - MONGO_PORT=27017
      - MONGO_DBNAME=unifi
    volumes:
      - /data/unifi:/config
    restart: unless-stopped
    networks:
      unifi-internal:
      unifi-net:
        ipv4_address: 192.168.240.2

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
        - subnet: 192.168.240.0/24
          gateway: 192.168.240.1
          ip_range: 192.168.240.2/32
```

**Important:** Adjust the following values for your network:
- Replace `YOUR_SECURE_PASSWORD_HERE` with the same password you used in Step 3
- Change `192.168.240.x` addresses to match your management network
- `TZ` to your timezone (e.g., `America/Chicago`, `Europe/London`)
- `parent: br0` - verify your interface with `ip addr`
- `ip_range: 192.168.240.2/32` - reserves only 1 IP for the controller

## Step 5: Create Startup Script

Create `/home/pi/.firewalla/config/post_main.d/start_unifi.sh`:

```bash
cat > /home/pi/.firewalla/config/post_main.d/start_unifi.sh << 'EOF'
#!/bin/bash
sudo systemctl start docker
sleep 5
cd /home/pi/.firewalla/run/docker/unifi
sudo docker-compose up -d
EOF

chmod +x /home/pi/.firewalla/config/post_main.d/start_unifi.sh
chown pi:pi /home/pi/.firewalla/config/post_main.d/start_unifi.sh
```

## Step 6: Start the Containers

```bash
cd /home/pi/.firewalla/run/docker/unifi
sudo docker-compose pull
sudo docker-compose up -d
```

## Step 7: Verify Installation

Check that both containers are running:

```bash
docker ps
```

You should see both `unifi` and `unifi-db` containers with status "Up".

## Step 8: Access the Controller

From a device on your management network (not the Firewalla itself), open:

```
https://192.168.240.2:8443
```

Accept the certificate warning and proceed with setup.

## Troubleshooting

### Check container logs
```bash
docker logs unifi
docker logs unifi-db
```

### Verify network configuration
```bash
docker network ls
docker network inspect unifi_unifi-net
```

### Restart containers
```bash
cd /home/pi/.firewalla/run/docker/unifi
sudo docker-compose restart
```

### Complete reset
```bash
cd /home/pi/.firewalla/run/docker/unifi
sudo docker-compose down -v
sudo rm -rf /data/unifi /data/unifi-db
# Then start from Step 2
```
