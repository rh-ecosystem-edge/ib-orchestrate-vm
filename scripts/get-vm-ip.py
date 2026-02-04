#!/usr/bin/env python3
"""
Look up a VM's IP address from libvirt DHCP leases or domifaddr.

Usage:
    get-vm-ip.py <vm_name> [--net <network_name>] [--mac <mac_address>] [--family v4|v6]
    get-vm-ip.py <vm_name> --wait [--timeout <seconds>] [--net <network_name>] [--mac <mac_address>] [--family v4|v6]

Environment variables (alternative to CLI args):
    VM_NAME          - VM name (required if not passed as arg)
    NET_NAME         - libvirt network name (optional)
    HOST_MAC         - MAC address to filter (optional)
    IP_STACK         - v4, v6, v4v6, or v6v4 (used to determine preferred family)
    WAIT_FOR_IP      - if non-empty, wait for the IP to appear
    WAIT_TIMEOUT     - timeout in seconds (default 300)
"""

import argparse
import os
import subprocess
import sys
import time
from typing import Optional


def _run(cmd: list[str]) -> tuple[int, str, str]:
    """Run a command and return (returncode, stdout, stderr)."""
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


def _get_leases_from_network(net_name: str, mac: Optional[str] = None) -> list[dict]:
    """Get DHCP leases from a libvirt network."""
    leases = []
    rc, stdout, _ = _run(["sudo", "virsh", "net-dhcp-leases", net_name])
    if rc != 0:
        return leases

    # Parse virsh net-dhcp-leases output (skip header lines)
    # Format: Expiry Time          MAC address        Protocol  IP address                Hostname        Client ID or DUID
    for line in stdout.strip().split("\n"):
        if not line or line.startswith("Expiry") or line.startswith("-"):
            continue
        parts = line.split()
        if len(parts) >= 5:
            lease_mac = parts[2].lower()
            protocol = parts[3]  # ipv4 or ipv6
            ip_with_prefix = parts[4]
            ip = ip_with_prefix.split("/")[0]

            if mac and lease_mac != mac.lower():
                continue

            leases.append({
                "mac": lease_mac,
                "ip": ip,
                "family": "v6" if protocol == "ipv6" else "v4",
            })
    return leases


def _get_ip_from_domifaddr(vm_name: str, mac: Optional[str] = None) -> list[dict]:
    """Get IP addresses from virsh domifaddr."""
    ips = []
    rc, stdout, _ = _run(["sudo", "virsh", "domifaddr", vm_name, "--source", "agent"])
    if rc != 0:
        # Try without agent source (uses ARP/lease)
        rc, stdout, _ = _run(["sudo", "virsh", "domifaddr", vm_name])
        if rc != 0:
            return ips

    # Parse output
    for line in stdout.strip().split("\n"):
        if not line or line.startswith("Name") or line.startswith("-"):
            continue
        parts = line.split()
        if len(parts) >= 4:
            iface_mac = parts[1].lower() if len(parts) > 1 else ""
            ip_with_prefix = parts[3] if len(parts) > 3 else ""
            ip = ip_with_prefix.split("/")[0]

            if mac and iface_mac != mac.lower():
                continue

            family = "v6" if ":" in ip else "v4"
            ips.append({
                "mac": iface_mac,
                "ip": ip,
                "family": family,
            })
    return ips


def get_vm_ip(
    vm_name: str,
    net_name: Optional[str] = None,
    mac: Optional[str] = None,
    family: Optional[str] = None,
) -> Optional[str]:
    """
    Get the IP address for a VM.

    Args:
        vm_name: libvirt VM name
        net_name: libvirt network name (optional, tries to get from domifaddr if not specified)
        mac: MAC address to filter by (optional)
        family: IP family preference ("v4" or "v6")

    Returns:
        IP address string or None if not found
    """
    ips = []

    # Try network DHCP leases first if network is specified
    if net_name:
        ips = _get_leases_from_network(net_name, mac)

    # Fall back to domifaddr
    if not ips:
        ips = _get_ip_from_domifaddr(vm_name, mac)

    if not ips:
        return None

    # Filter out link-local IPv6 addresses (fe80::) - they're not routable
    ips = [i for i in ips if not i["ip"].startswith("fe80:")]

    if not ips:
        return None

    # Filter by family if specified
    if family:
        family_ips = [i for i in ips if i["family"] == family]
        if family_ips:
            return family_ips[0]["ip"]
        # If family filter specified but no match, return None (don't fall back)
        return None

    # Return first IP
    return ips[0]["ip"]


def wait_for_ip(
    vm_name: str,
    timeout: int = 300,
    net_name: Optional[str] = None,
    mac: Optional[str] = None,
    family: Optional[str] = None,
) -> Optional[str]:
    """Wait for a VM to get an IP address."""
    start = time.time()
    while time.time() - start < timeout:
        ip = get_vm_ip(vm_name, net_name, mac, family)
        if ip:
            return ip
        time.sleep(5)
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Get VM IP address from libvirt")
    parser.add_argument("vm_name", nargs="?", help="VM name")
    parser.add_argument("--net", help="libvirt network name")
    parser.add_argument("--mac", help="MAC address to filter")
    parser.add_argument("--family", choices=["v4", "v6"], help="IP family preference")
    parser.add_argument("--wait", action="store_true", help="Wait for IP to appear")
    parser.add_argument("--timeout", type=int, default=300, help="Timeout in seconds (default 300)")
    args = parser.parse_args()

    # Get values from args or environment
    vm_name = args.vm_name or os.environ.get("VM_NAME", "")
    net_name = args.net or os.environ.get("NET_NAME", "")
    mac = args.mac or os.environ.get("HOST_MAC", "")
    wait = args.wait or os.environ.get("WAIT_FOR_IP", "") != ""
    timeout = args.timeout
    if os.environ.get("WAIT_TIMEOUT"):
        try:
            timeout = int(os.environ["WAIT_TIMEOUT"])
        except ValueError:
            pass

    # Determine family from IP_STACK if not specified
    family = args.family
    if not family:
        ip_stack = os.environ.get("IP_STACK", "v4")
        if ip_stack in ("v4", "v4v6"):
            family = "v4"
        elif ip_stack in ("v6", "v6v4"):
            family = "v6"

    if not vm_name:
        print("Error: VM name is required", file=sys.stderr)
        return 1

    if wait:
        ip = wait_for_ip(vm_name, timeout, net_name or None, mac or None, family)
    else:
        ip = get_vm_ip(vm_name, net_name or None, mac or None, family)

    if ip:
        print(ip)
        return 0
    else:
        print(f"Error: Could not get IP for VM {vm_name}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
