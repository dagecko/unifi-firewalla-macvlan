#!/bin/bash
# Manual update script for monitoring service on Firewalla
# Run this on your Firewalla to update the monitoring service with fixes

echo "Stopping monitoring service..."
sudo systemctl stop unifi-monitor

echo "Downloading updated monitor script..."
curl -sL "https://raw.githubusercontent.com/dagecko/unifi-firewalla-macvlan/main/unifi-monitor.sh" -o /tmp/unifi-monitor.sh

echo "Installing updated script..."
sudo mv /tmp/unifi-monitor.sh /home/pi/.firewalla/config/post_main.d/unifi-monitor.sh
sudo chmod +x /home/pi/.firewalla/config/post_main.d/unifi-monitor.sh

echo "Starting monitoring service..."
sudo systemctl start unifi-monitor

echo ""
echo "Monitoring service updated and restarted!"
echo ""
echo "View logs with: sudo journalctl -u unifi-monitor -f"
echo "Check status with: sudo systemctl status unifi-monitor"
