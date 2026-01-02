# VLAN Networking Architecture

This document explains how UniFi Controller container networking works on VLAN deployments with Firewalla, including the technical challenges and solutions.

## Overview

When deploying the UniFi Controller on a VLAN network (e.g., 192.168.240.0/24), the networking setup is more complex than native LAN deployments due to:

1. **Macvlan limitations** - Host and container on the same parent interface cannot communicate directly
2. **Policy routing** - Firewalla uses multiple routing tables with priority-based rules
3. **NAT requirements** - Container traffic must be NAT'd for internet access

## Network Topology

```
Internet (WAN)
     ↕ eth0 (163.182.75.6)
┌────────────────────────────────────────┐
│         Firewalla Gold Pro              │
│  ┌──────────────────────────────────┐  │
│  │ Policy Routing Tables:           │  │
│  │ • main (priority 32766)          │  │
│  │ • lan_routable (priority 5002)   │  │
│  │ • br0_local (priority 501)       │  │
│  └──────────────────────────────────┘  │
│                                         │
│     eth1.240 (VLAN interface)          │
│          ↓                              │
│     br0 (192.168.240.1/24)             │
│      ├─ unifi-shim@br0 (macvlan)       │
│      │   └─ 192.168.240.254            │
│      └─ Docker macvlan parent          │
└─────────────────────────────────────────┘
          ↓
    ┌──────────────────────────────┐
    │  Docker Macvlan Network      │
    │  (unifi_unifi-net)           │
    │                              │
    │  Container eth1@br0          │
    │  └─ 192.168.240.2/24         │
    │     Gateway: 192.168.240.1   │
    └──────────────────────────────┘
          ↕
    External Devices
    (e.g., Mac on 192.168.101.x)
```

## Traffic Flows

### 1. External Device → Container (WORKS via Shim)

Example: Mac (192.168.101.51) accessing UniFi controller UI

```
Mac (192.168.101.51)
  → Firewalla routing (br7 → br0)
  → Route: 192.168.240.2 dev unifi-shim
  → unifi-shim interface (macvlan)
  → Container eth1 (192.168.240.2)
```

**Key points:**
- Shim interface enables external access to container
- Works around macvlan limitation (two macvlan interfaces on same parent CAN communicate)
- Route: `192.168.240.2 dev unifi-shim scope link`

### 2. Container → External Device (WORKS via br0)

Example: Container replying to Mac

```
Container (192.168.240.2)
  → Default gateway: 192.168.240.1
  → Container eth1 (macvlan)
  → br0 bridge
  → Firewalla routing (br0 → br7)
  → Mac (192.168.101.51)
```

**Key points:**
- Container uses br0 (192.168.240.1) as gateway
- Traffic flows directly through bridge (no shim needed)
- Firewalla routes between VLANs

### 3. Container → Internet (REQUIRES SPECIAL ROUTING)

Example: Container accessing 8.8.8.8 for DNS or reaching Ubiquiti cloud

```
OUTBOUND:
Container (192.168.240.2)
  → Default gateway: 192.168.240.1
  → Container eth1 (macvlan)
  → br0 bridge
  → Policy rule: from 192.168.240.0/24 lookup lan_routable (priority 5002)
  → lan_routable table: default via 163.182.75.1 dev eth0
  → NAT POSTROUTING: 192.168.240.2 → 163.182.75.6 (WAN IP)
  → Internet (8.8.8.8)

RETURN:
Internet (8.8.8.8)
  → Firewalla WAN (163.182.75.6)
  → NAT PREROUTING: 163.182.75.6 → 192.168.240.2 (de-NAT)
  → Policy rule: to 192.168.240.2 lookup main (priority 500) ← KEY FIX
  → main table: 192.168.240.2 dev unifi-shim
  → unifi-shim interface (macvlan)
  → Container eth1 (192.168.240.2)
```

**Key points:**
- **Outbound**: lan_routable table must have default route to WAN
- **NAT required**: Private IP (192.168.240.2) can't route on public internet
- **Return traffic**: Priority 500 rule forces use of shim (overrides br0_local table at 501)
- Without priority 500 rule, replies try to use br0_local table which fails (macvlan limitation)

### 4. Firewalla Host → Container (DOES NOT WORK)

```
Firewalla (192.168.240.1)
  → br0 interface
  ✗ FAILS - macvlan limitation
  ✗ Host and container on same parent cannot communicate
```

**Why it fails:**
- Linux kernel limitation: host interface and macvlan container on same parent are isolated
- This is by design in macvlan architecture
- Workaround: Use shim interface with specific IP for host access

## Technical Challenges & Solutions

### Challenge 1: No Default Route in lan_routable Table

**Problem:**
```bash
$ ip route get 8.8.8.8 from 192.168.240.2
RTNETLINK answers: Network is unreachable
```

Policy routing rule sends VLAN traffic to `lan_routable` table, but it only had local routes:
```bash
$ ip route show table lan_routable
192.168.240.0/24 dev br0 scope link
192.168.240.2 dev unifi-shim scope link
# No default route!
```

**Solution:**
```bash
sudo ip route add default via 163.182.75.1 dev eth0 table lan_routable
```

Now container traffic can reach the internet.

### Challenge 2: Return Traffic Uses Wrong Routing Table

**Problem:**
```bash
$ ip route get 8.8.8.8 to 192.168.240.2
192.168.240.2 dev br0 table br0_local src 192.168.240.1
```

Return traffic was using `br0_local` table (priority 501) which routes via br0 directly. This fails due to macvlan limitation - host can't communicate with container on same parent.

**Evidence:**
```bash
$ sudo tcpdump -i unifi-shim -n icmp
# Shows container → 8.8.8.8 requests
# NO replies from 8.8.8.8 → container
```

**Solution:**
```bash
sudo ip rule add to 192.168.240.2 lookup main priority 500
```

This rule has higher priority (500) than br0_local (501), forcing return traffic to use the main table which has the shim route:
```bash
$ ip route show | grep 192.168.240.2
192.168.240.2 dev unifi-shim scope link
```

Now replies flow: WAN → Firewalla → shim → container ✓

### Challenge 3: NAT vs No-NAT Decision

**Problem:**

- **With NAT exemption** (`iptables -t nat -I POSTROUTING -s 192.168.240.2 -j ACCEPT`):
  - Packets leave with source 192.168.240.2 (private IP)
  - Internet hosts can't reply to private IPs
  - Result: No replies

- **Without NAT exemption** (normal masquerading):
  - Packets leave with source 163.182.75.6 (WAN IP)
  - Replies addressed to 163.182.75.6
  - Conntrack de-NATs to 192.168.240.2
  - But routing sends to br0_local table (fails)

**Solution:**

Use NAT (masquerading) + priority 500 routing rule:

1. **Outbound**: NAT converts 192.168.240.2 → 163.182.75.6 ✓
2. **Inbound**: Conntrack de-NATs 163.182.75.6 → 192.168.240.2 ✓
3. **Routing**: Priority 500 rule sends to shim ✓

```bash
# NAT happens automatically via Firewalla's FW_POSTROUTING chain
# No exemption needed - let normal NAT work

# Policy rule ensures de-NAT'd packets route correctly
sudo ip rule add to 192.168.240.2 lookup main priority 500
```

## Policy Routing Rules

Firewalla uses priority-based routing rules. Lower number = higher priority.

**Relevant rules for VLAN container:**

```bash
$ ip rule list
0:    from all lookup local                    # Highest priority
500:  from all to 192.168.240.2 lookup main   ← OUR FIX (return traffic)
501:  from all iif br0 lookup br0_local        # Would route via br0 (fails)
501:  from all iif lo lookup br0_local
5002: from all iif br0 lookup lan_routable
5002: from 192.168.240.0/24 lookup lan_routable ← Container outbound
32766: from all lookup main                     # Default
```

**Flow:**
- **Outbound** (from 192.168.240.2): Matches rule 5002 → lan_routable table → WAN
- **Inbound** (to 192.168.240.2): Matches rule 500 → main table → shim route

## Routing Tables

### main table
```bash
$ ip route show
default via 163.182.75.1 dev eth0
192.168.101.0/24 dev br7
192.168.240.0/24 dev br0
192.168.240.2 dev unifi-shim scope link  ← Shim route for container
```

### lan_routable table
```bash
$ ip route show table lan_routable
default via 163.182.75.1 dev eth0       ← CRITICAL for internet access
192.168.101.0/24 dev br7
192.168.240.0/24 dev br0
192.168.240.2 dev unifi-shim scope link
```

### br0_local table
```bash
$ ip route show table br0_local
broadcast 192.168.240.0 dev br0
192.168.240.0/24 dev br0
local 192.168.240.1 dev br0
broadcast 192.168.240.255 dev br0
```

Note: This table routes via br0 directly (no shim), which fails for container due to macvlan limitation.

## Installation Script Implementation

The install script automatically detects VLAN deployments and applies the fixes:

```bash
# VLAN detection (install.sh:323-333)
VLAN_MEMBERS=$(brctl show ${PARENT_INTERFACE} 2>/dev/null | tail -n +2 | awk '{print $NF}')
if echo "$VLAN_MEMBERS" | grep -q "\."; then
    IS_VLAN="true"
    VLAN_INTERFACE=$(echo "$VLAN_MEMBERS" | grep "\." | head -1)
    echo -e "${YELLOW}VLAN detected (using ${VLAN_INTERFACE})${NC}"
fi

# Apply VLAN-specific routing (install.sh:740-761)
if [ "$IS_VLAN" = "true" ]; then
    # Get WAN gateway
    WAN_GATEWAY=$(ip route show default | grep -oP '(?<=via )[^ ]+' | head -1)
    WAN_INTERFACE=$(ip route show default | grep -oP '(?<=dev )[^ ]+' | head -1)

    # Add default route to lan_routable table
    sudo ip route add default via ${WAN_GATEWAY} dev ${WAN_INTERFACE} table lan_routable

    # Add policy routing rule for return traffic
    sudo ip rule add to ${CONTROLLER_IP} lookup main priority 500
fi
```

## Verification Commands

### Check VLAN Configuration
```bash
# Verify VLAN interface
brctl show br0
# Should show: eth1.240

# Check if VLAN detection worked
ip link show eth1.240
```

### Check Routing Configuration
```bash
# Verify default route in lan_routable table
ip route show table lan_routable | grep default
# Should show: default via 163.182.75.1 dev eth0

# Verify priority 500 rule exists
ip rule list | grep "500:"
# Should show: 500: from all to 192.168.240.2 lookup main

# Verify shim route
ip route show | grep "192.168.240.2"
# Should show: 192.168.240.2 dev unifi-shim scope link
```

### Test Connectivity
```bash
# Test container internet access
sudo docker exec unifi-routing-fixer ping -c 3 8.8.8.8

# Test DNS resolution
sudo docker exec unifi-routing-fixer nslookup google.com

# Test external access (from your Mac/PC)
curl -k https://192.168.240.2:8443

# Check NAT is working
sudo tcpdump -i eth0 -n icmp and host 8.8.8.8
# Should show: 163.182.75.6 ↔ 8.8.8.8 (NAT'd traffic)
```

### Debug Traffic Flow
```bash
# Watch shim interface
sudo tcpdump -i unifi-shim -n

# Watch container interface
sudo docker exec unifi-routing-fixer tcpdump -i eth1 -n

# Check conntrack entries
sudo conntrack -L | grep 192.168.240.2

# Trace routing decisions
ip route get 8.8.8.8 from 192.168.240.2 iif br0
# Should show: ... via 163.182.75.1 dev eth0 table lan_routable
```

## Comparison: Native LAN vs VLAN

| Aspect | Native LAN (br7) | VLAN (br0 with eth1.240) |
|--------|------------------|--------------------------|
| **Macvlan parent** | br7 (physical eth1) | br0 (VLAN interface eth1.240) |
| **Routing table** | Works with default routes | Requires lan_routable table config |
| **Internet access** | Direct via main table | Requires default route in lan_routable |
| **Return traffic** | Uses main table | Requires priority 500 rule |
| **Shim needed** | Yes (for host access) | Yes (for external + return traffic) |
| **NAT** | Normal masquerading | Normal masquerading |
| **Complexity** | Simple | Complex (policy routing) |
| **Sidecar container** | No | Yes (routing-fixer) |

## Troubleshooting

### Container can't ping gateway (192.168.240.1)
**Expected behavior** - this is normal! Macvlan containers cannot ping the host interface on the same parent. As long as internet access works, this is fine.

### Container can't reach internet
```bash
# Check lan_routable table has default route
ip route show table lan_routable | grep default

# If missing, add it:
sudo ip route add default via $(ip route | grep default | awk '{print $3}') dev eth0 table lan_routable
```

### External devices can't reach container
```bash
# Check shim route exists
ip route show | grep "192.168.240.2"

# If missing, add it:
sudo ip route add 192.168.240.2 dev unifi-shim scope link
sudo ip route add 192.168.240.2 dev unifi-shim table lan_routable scope link
```

### Internet works but replies don't reach container
```bash
# Check priority 500 rule exists
ip rule list | grep "500:"

# If missing, add it:
sudo ip rule add to 192.168.240.2 lookup main priority 500
```

### Check conntrack for packet flow
```bash
# While pinging, check conntrack
sudo docker exec unifi-routing-fixer ping -c 1 8.8.8.8 &
sleep 1
sudo conntrack -L -p icmp | grep 192.168.240.2
```

**Good output:**
```
src=192.168.240.2 dst=8.8.8.8 ... src=8.8.8.8 dst=163.182.75.6 ...
```
Shows NAT is working and replies are coming back.

**Bad output:**
```
[UNREPLIED] src=8.8.8.8 dst=192.168.240.2
```
Means replies are addressed correctly but not being routed to container.

## References

- [Docker Macvlan Documentation](https://docs.docker.com/network/drivers/macvlan/)
- [Linux Policy Routing](https://www.kernel.org/doc/html/latest/networking/policy-routing.html)
- [Firewalla Gold Pro Documentation](https://help.firewalla.com/)
- [ip-route(8) man page](https://man7.org/linux/man-pages/man8/ip-route.8.html)

## Credits

Developed through extensive debugging and testing on Firewalla Gold Pro with VLAN 240 (192.168.240.0/24).

Solution discovered after 130+ messages of troubleshooting, identifying the precise interaction between:
- Macvlan container networking
- Firewalla's policy routing architecture
- Linux kernel NAT/conntrack behavior
- Bridge interface limitations with VLAN sub-interfaces
