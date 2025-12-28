# Advanced Configuration

## Accessing the Controller from Firewalla (Shim Interface)

Due to how macvlan networking works, the Firewalla host cannot directly communicate with containers on the macvlan network. This is a Linux kernel limitation, not a Docker issue.

If you need to access the UniFi Controller from Firewalla itself (for health checks, API calls, or direct access), you can create a "shim" interface.

### How It Works

We create a secondary macvlan interface on the host and assign it an IP on the same subnet. This gives Firewalla a "side door" to communicate with the containers.

### Setup

1. **Choose an IP for the shim interface** (e.g., 192.168.240.254)

2. **Create the shim interface manually** (for testing):

```bash
sudo ip link add unifi-shim link br0 type macvlan mode bridge
sudo ip addr add 192.168.240.254/32 dev unifi-shim
sudo ip link set unifi-shim up
sudo ip route add 192.168.240.2/32 dev unifi-shim
```

**Note:** MongoDB runs on an internal Docker network and doesn't need a route.

3. **Test connectivity**:

```bash
ping -c 3 192.168.240.2
curl -k https://192.168.240.2:8443
```

### Making It Persistent

Add the shim setup to your startup script. Edit `/home/pi/.firewalla/config/post_main.d/start_unifi.sh`:

```bash
#!/bin/bash
sudo systemctl start docker
sleep 5
cd /home/pi/.firewalla/run/docker/unifi
sudo docker-compose up -d

# Create shim interface for host access to UniFi Controller
sleep 10
sudo ip link add unifi-shim link br0 type macvlan mode bridge 2>/dev/null || true
sudo ip addr add 192.168.240.254/32 dev unifi-shim 2>/dev/null || true
sudo ip link set unifi-shim up 2>/dev/null || true
sudo ip route add 192.168.240.2/32 dev unifi-shim 2>/dev/null || true
```

### Health Check Script

Once the shim is in place, you can create health checks. Save as `/home/pi/.firewalla/run/docker/unifi/healthcheck.sh`:

```bash
#!/bin/bash

# UniFi Controller Health Check
# Returns 0 if healthy, 1 if unhealthy

CONTROLLER_IP="192.168.240.2"

# Check if containers are running
UNIFI_RUNNING=$(docker inspect -f '{{.State.Running}}' unifi 2>/dev/null)
MONGO_RUNNING=$(docker inspect -f '{{.State.Running}}' unifi-db 2>/dev/null)

if [ "$UNIFI_RUNNING" != "true" ]; then
    echo "CRITICAL: UniFi container not running"
    exit 1
fi

if [ "$MONGO_RUNNING" != "true" ]; then
    echo "CRITICAL: MongoDB container not running"
    exit 1
fi

# Check if controller responds (requires shim interface)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k --max-time 10 "https://${CONTROLLER_IP}:8443" 2>/dev/null)

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ]; then
    echo "OK: UniFi Controller healthy (HTTP $HTTP_CODE)"
    exit 0
else
    echo "WARNING: UniFi Controller returned HTTP $HTTP_CODE"
    exit 1
fi
```

Make it executable:

```bash
chmod +x /home/pi/.firewalla/run/docker/unifi/healthcheck.sh
```

### Cron-based Monitoring

To run health checks periodically and log results:

```bash
# Add to crontab (crontab -e)
*/5 * * * * /home/pi/.firewalla/run/docker/unifi/healthcheck.sh >> /data/unifi/healthcheck.log 2>&1
```

### Removing the Shim

If you need to remove the shim interface:

```bash
sudo ip link delete unifi-shim
```

And remove the shim-related lines from `start_unifi.sh`.

## API Access

With the shim in place, you can access the UniFi API from Firewalla:

```bash
# Get a login cookie
curl -k -c /tmp/unifi-cookie -b /tmp/unifi-cookie \
  -d '{"username":"admin","password":"yourpassword"}' \
  -H "Content-Type: application/json" \
  https://192.168.240.2:8443/api/login

# Query devices
curl -k -c /tmp/unifi-cookie -b /tmp/unifi-cookie \
  https://192.168.240.2:8443/api/s/default/stat/device
```

## Troubleshooting

### Shim interface disappeared after reboot
Ensure the shim commands are in `/home/pi/.firewalla/config/post_main.d/start_unifi.sh` and the script is executable.

### "RTNETLINK answers: File exists" errors
This is normal — it means the interface/route already exists. The `2>/dev/null || true` suppresses these.

### Cannot ping container IPs
Verify the shim is up:
```bash
ip addr show unifi-shim
ip route | grep unifi-shim
```
