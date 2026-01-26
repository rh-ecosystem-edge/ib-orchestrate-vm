#!/usr/bin/env python3

import ipaddress
import os
import sys
from typing import Optional


def _env(name: str, default: Optional[str] = None, required: bool = False) -> str:
    v = os.environ.get(name, default)
    if required and (v is None or v == ""):
        raise SystemExit(f"render-image-based-installation-config: missing env {name}")
    return v if v is not None else ""


def _indent(text: str, spaces: int) -> str:
    prefix = " " * spaces
    lines = text.splitlines() or [""]
    return "\n".join(prefix + line for line in lines)


def _stack_order(ip_stack: str) -> list[str]:
    if ip_stack == "v4":
        return ["v4"]
    if ip_stack == "v6":
        return ["v6"]
    if ip_stack == "v4v6":
        return ["v4", "v6"]
    if ip_stack == "v6v4":
        return ["v6", "v4"]
    raise SystemExit(f"render-image-based-installation-config: invalid IP_STACK={ip_stack} (expected v4|v6|v4v6|v6v4)")


def _gateway_for_cidr(cidr: str) -> str:
    n = ipaddress.ip_network(cidr, strict=False)
    return str(ipaddress.ip_address(int(n.network_address) + 1))


def _prefixlen_for_cidr(cidr: str) -> int:
    return ipaddress.ip_network(cidr, strict=False).prefixlen


def _render_network_config(ip_stack: str) -> str:
    """
    Render a simple nmstate networkConfig for a single interface (enp1s0),
    supporting v4/v6/dual-stack based on IP_STACK.
    """
    order = _stack_order(ip_stack)
    host_mac = _env("HOST_MAC", required=True)

    host_ip_v4 = _env("HOST_IP_V4", "")
    host_ip_v6 = _env("HOST_IP_V6", "")
    mn_v4 = _env("MACHINE_NETWORK_V4", "")
    mn_v6 = _env("MACHINE_NETWORK_V6", "")

    iface_lines: list[str] = [
        "networkConfig:",
        "  interfaces:",
        "    - name: enp1s0",
        "      type: ethernet",
        "      state: up",
        f"      mac-address: {host_mac}",
    ]

    route_lines: list[str] = ["  routes:", "    config:"]
    dns_servers: list[str] = []

    if "v4" in order:
        if not (host_ip_v4 and mn_v4):
            raise SystemExit("render-image-based-installation-config: IP_STACK includes v4 but HOST_IP_V4 and MACHINE_NETWORK_V4 are not set")
        gw4 = _gateway_for_cidr(mn_v4)
        dns_servers.append(gw4)
        iface_lines.extend(
            [
                "      ipv4:",
                "        enabled: true",
                "        dhcp: false",
                "        address:",
                f"          - ip: {host_ip_v4}",
                f"            prefix-length: {_prefixlen_for_cidr(mn_v4)}",
            ]
        )
        route_lines.extend(
            [
                "    - destination: 0.0.0.0/0",
                f"      next-hop-address: {gw4}",
                "      next-hop-interface: enp1s0",
                "      table-id: 254",
            ]
        )

    if "v6" in order:
        if not (host_ip_v6 and mn_v6):
            raise SystemExit("render-image-based-installation-config: IP_STACK includes v6 but HOST_IP_V6 and MACHINE_NETWORK_V6 are not set")
        gw6 = _gateway_for_cidr(mn_v6)
        dns_servers.append(gw6)
        iface_lines.extend(
            [
                "      ipv6:",
                "        enabled: true",
                "        dhcp: false",
                "        autoconf: false",
                "        address:",
                f"          - ip: {host_ip_v6}",
                f"            prefix-length: {_prefixlen_for_cidr(mn_v6)}",
            ]
        )
        route_lines.extend(
            [
                "    - destination: ::/0",
                f"      next-hop-address: {gw6}",
                "      next-hop-interface: enp1s0",
                "      table-id: 254",
            ]
        )

    dns_lines = ["  dns-resolver:", "    config:", "      server:"]
    dns_lines.extend([f"        - {s}" for s in dns_servers])

    return "\n" + "\n".join([*iface_lines, *route_lines, *dns_lines]) + "\n"


def main() -> int:
    seed_image = _env("SEED_IMAGE", required=True)
    seed_version = _env("SEED_VERSION", required=True)
    installation_disk = _env("INSTALLATION_DISK", required=True)
    extra_partition_start = _env("IBI_EXTRA_PARTITION_START", required=True)
    extra_partition_label = _env("EXTRA_PARTITION_LABEL", "var-lib-containers")
    pull_secret = _env("PULL_SECRET", required=True)
    ssh_key = _env("SSH_KEY", required=True)
    ip_stack = _env("IP_STACK", default="v4")

    out = "\n".join(
        [
            "apiVersion: v1beta1",
            "kind: ImageBasedInstallationConfig",
            "metadata:",
            "  name: image-based-installation-config",
            f"seedImage: {seed_image}",
            f"seedVersion: {seed_version}",
            f"installationDisk: {installation_disk}",
            f"extraPartitionLabel: {extra_partition_label}",
            f'extraPartitionStart: "{extra_partition_start}"',
            "pullSecret: |",
            _indent(pull_secret, 2),
            "sshKey: |",
            _indent(ssh_key, 2),
        ]
    )

    # DHCP mode: keep config minimal (no nmstate networkConfig).
    if os.environ.get("DHCP", "") == "":
        out += _render_network_config(ip_stack)

    sys.stdout.write(out + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


