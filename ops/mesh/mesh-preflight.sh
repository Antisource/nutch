#!/usr/bin/env bash
echo "===== $(hostname) kernel $(uname -r)"
echo "-- addresses"; ip -br addr
echo "-- hadoop lines in /etc/hosts"; grep -E 'hadoop' /etc/hosts
echo "-- listening Java sockets"; sudo ss -ltnp | grep java | awk '{print $4, $6}' | sort
echo "-- wireguard tool and module"
command -v wg || echo "wg tool not installed"
if lsmod | grep -q wireguard; then echo "module loaded"; elif modinfo wireguard >/dev/null 2>&1; then echo "module available"; else echo "no wireguard module"; fi
echo "-- firewall rules"; sudo iptables -S 2>&1 | head -6
echo "-- package"; apt-cache policy wireguard-tools | head -3
