# UniFi Controller on Firewalla Gold Pro (Macvlan Setup)

Install UniFi Network Application in Docker on Firewalla Gold Series boxes using macvlan networking. This places the controller directly on your management network rather than an isolated Docker bridge network.

## Why Macvlan?

Most UniFi-on-Firewalla guides use a separate Docker bridge network (172.16.1.0/24), requiring routing tricks and inform URL changes. This approach puts the controller directly on your existing management VLAN, which:

- Simplifies migration from UDM/Cloud Key (devices stay on same L2 network)
- Enables cleaner network architecture (management plane separated from user traffic)
- Allows backup restoration without changing inform URLs on every device
- Matches enterprise best practices for out-of-band management

## Requirements

- Firewalla Gold, Gold SE, Gold Plus, or Gold Pro (not recommended for Purple series due to memory constraints)
- SSH access to your Firewalla
- A dedicated management network/VLAN (e.g., 192.168.240.0/24)
- One available IP address for the UniFi Controller

## Architecture

```
ISP → Firewalla Gold Pro
        ├── Management Network (e.g., 192.168.240.0/24)
        │     ├── Firewalla (192.168.240.1)
        │     ├── UniFi Controller Docker (192.168.240.2) ← macvlan
        │     └── UniFi APs/Switches (management interfaces)
        ├── User Network (e.g., 192.168.1.0/24)
        └── IoT/Camera Networks (as needed)

Internal Docker Network (not exposed to network):
        └── MongoDB ← only accessible by UniFi Controller
```

## Quick Install

SSH into your Firewalla and run:

```bash
bash <(curl -sL "https://raw.githubusercontent.com/dagecko/unifi-firewalla-macvlan/main/install.sh")
```

Or download and run:

```bash
curl -sL "https://raw.githubusercontent.com/dagecko/unifi-firewalla-macvlan/main/install.sh" -o /tmp/install.sh
bash /tmp/install.sh
```

The script will prompt you for:
- Controller IP address
- MongoDB password (for internal use only)
- Number of IPs to reserve (if you plan to add more containers)
- Timezone
- Optional: Shim interface for host access

## Manual Install

See [manual-install.md](manual-install.md) for step-by-step instructions.

## Post-Install: Migrating from UDM/Cloud Key

1. Access the controller at `https://<controller-ip>:8443`
2. During setup, choose **"Restore from backup"**
3. Upload your `.unf` backup file from the old controller
4. Update the inform URL in Settings → System → Advanced to `http://<controller-ip>:8080/inform`
5. Power cycle your UDM/Cloud Key to release the devices
6. Devices should automatically adopt to the new controller

## Updating

**Option 1: Using the update script (recommended)**

```bash
curl -sL "https://raw.githubusercontent.com/dagecko/unifi-firewalla-macvlan/main/update.sh" | bash
```

**Option 2: Manual update**

```bash
cd /home/pi/.firewalla/run/docker/unifi
sudo docker-compose pull
sudo docker-compose up -d
sudo docker system prune -f
```

## Uninstalling

```bash
curl -sL "https://raw.githubusercontent.com/dagecko/unifi-firewalla-macvlan/main/uninstall.sh" | bash
```

Or manually:

```bash
cd /home/pi/.firewalla/run/docker/unifi
sudo docker-compose down -v
sudo rm -rf /data/unifi /data/unifi-db
sudo rm -rf /home/pi/.firewalla/run/docker/unifi
sudo rm -f /home/pi/.firewalla/config/post_main.d/start_unifi.sh
```

## Important Notes

### Macvlan Limitation

Due to how macvlan works, the Firewalla host cannot directly communicate with the UniFi Controller container. This is expected behavior. Access the controller from any other device on the management network.

If you need to access the controller from Firewalla itself (for health checks, API access, or monitoring), enable the shim interface during installation or see [advanced.md](advanced.md) for manual setup.

### Network Security

MongoDB runs on an internal Docker bridge network and is **not** exposed to your management network. Only the UniFi Controller container can communicate with it. This follows the principle of least exposure and is more secure than exposing the database to the network.

### Resource Usage

The UniFi Network Application uses significant resources:
- ~800MB-1GB RAM
- ~800MB disk space (more with logs/backups over time)

Monitor with: `docker stats`

### Persistence

The install script creates `/home/pi/.firewalla/config/post_main.d/start_unifi.sh` to ensure Docker and the containers start after Firewalla reboots.

## Troubleshooting

### Container won't start
```bash
docker logs unifi
docker logs unifi-db
```

### MongoDB connection issues
Ensure MongoDB is healthy before UniFi starts:
```bash
docker ps
```
Both containers should show as "Up" with healthy status.

### Network unreachable
Verify macvlan network exists:
```bash
docker network ls
docker network inspect unifi_unifi-net
```

### Reset and start over
Run the uninstall script, then reinstall.

## Credits

- Based on [Firewalla's official UniFi guide](https://help.firewalla.com/hc/en-us/articles/360053441074)
- Inspired by [mbierman's unifi-installer-for-Firewalla](https://github.com/mbierman/unifi-installer-for-Firewalla)
- Uses [LinuxServer.io's UniFi Network Application image](https://github.com/linuxserver/docker-unifi-network-application)

## License

GPL-3.0

## Disclaimer

This script is provided as-is. It should not affect Firewalla's core router functionality or compromise security, but use at your own risk. Always maintain backups of your UniFi configuration.
