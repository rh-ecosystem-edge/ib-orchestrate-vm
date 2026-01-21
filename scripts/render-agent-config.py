#!/usr/bin/env python3

import ipaddress
import os
import sys
from typing import Optional


def _env(name: str, default: Optional[str] = None, required: bool = False) -> str:
    v = os.environ.get(name, default)
    if required and (v is None or v == ""):
        raise SystemExit(f"render-agent-config: missing env {name}")
    return v if v is not None else ""


def _stack_order(ip_stack: str) -> list[str]:
    if ip_stack == "v4":
        return ["v4"]
    if ip_stack == "v6":
        return ["v6"]
    if ip_stack == "v4v6":
        return ["v4", "v6"]
    if ip_stack == "v6v4":
        return ["v6", "v4"]
    raise SystemExit(f"render-agent-config: invalid IP_STACK={ip_stack} (expected v4|v6|v4v6|v6v4)")


def _gateway_for_cidr(cidr: str) -> str:
    n = ipaddress.ip_network(cidr, strict=False)
    return str(ipaddress.ip_address(int(n.network_address) + 1))


def _prefixlen_for_cidr(cidr: str) -> int:
    return ipaddress.ip_network(cidr, strict=False).prefixlen


def main() -> int:
    vm_name = _env("VM_NAME", required=True)
    host_mac = _env("HOST_MAC", required=True)
    ip_stack = _env("IP_STACK", default="v4")

    order = _stack_order(ip_stack)

    host_ip_v4 = _env("HOST_IP_V4", default="")
    host_ip_v6 = _env("HOST_IP_V6", default="")
    mn_v4 = _env("MACHINE_NETWORK_V4", default="")
    mn_v6 = _env("MACHINE_NETWORK_V6", default="")

    # Determine primary rendezvous IP based on stack order
    if order[0] == "v4":
        rendezvous = host_ip_v4 or _env("HOST_IP_V4", required=True)
    else:
        rendezvous = host_ip_v6 or _env("HOST_IP_V6", required=True)

    # If DHCP mode is enabled, emit minimal agent config (no nmstate)
    if os.environ.get("DHCP", "") != "":
        sys.stdout.write(
            "\n".join(
                [
                    "apiVersion: v1alpha1",
                    "kind: AgentConfig",
                    "metadata:",
                    f"  name: {vm_name}-sno-cluster",
                    f"rendezvousIP: {rendezvous}",
                    "hosts:",
                    f"  - hostname: {vm_name}",
                    "    interfaces:",
                    "      - name: eno1",
                    f"        macAddress: {host_mac}",
                    "",
                ]
            )
        )
        return 0

    # Static nmstate config
    iface_lines: list[str] = [
        "        - name: eno1",
        "          type: ethernet",
        "          state: up",
        f"          mac-address: {host_mac}",
    ]

    route_lines: list[str] = ["      routes:", "        config:"]
    dns_servers: list[str] = []

    if "v4" in order:
        if not (host_ip_v4 and mn_v4):
            raise SystemExit("render-agent-config: IP_STACK includes v4 but HOST_IP_V4 and MACHINE_NETWORK_V4 are not set")
        gw4 = _gateway_for_cidr(mn_v4)
        dns_servers.append(gw4)
        iface_lines.extend(
            [
                "          ipv4:",
                "            enabled: true",
                "            address:",
                f"              - ip: {host_ip_v4}",
                f"                prefix-length: {_prefixlen_for_cidr(mn_v4)}",
            ]
        )
        route_lines.extend(
            [
                f"        - next-hop-address: {gw4}",
                "          next-hop-interface: eno1",
                "          destination: 0.0.0.0/0",
            ]
        )

    if "v6" in order:
        if not (host_ip_v6 and mn_v6):
            raise SystemExit("render-agent-config: IP_STACK includes v6 but HOST_IP_V6 and MACHINE_NETWORK_V6 are not set")
        gw6 = _gateway_for_cidr(mn_v6)
        dns_servers.append(gw6)
        iface_lines.extend(
            [
                "          ipv6:",
                "            enabled: true",
                "            address:",
                f"              - ip: {host_ip_v6}",
                f"                prefix-length: {_prefixlen_for_cidr(mn_v6)}",
            ]
        )
        route_lines.extend(
            [
                f"        - next-hop-address: {gw6}",
                "          next-hop-interface: eno1",
                "          destination: ::/0",
            ]
        )

    dns_lines = ["      dns-resolver:", "        config:", "          server:"]
    dns_lines.extend([f"            - {s}" for s in dns_servers])

    sys.stdout.write(
        "\n".join(
            [
                "apiVersion: v1alpha1",
                "kind: AgentConfig",
                "metadata:",
                f"  name: {vm_name}-sno-cluster",
                f"rendezvousIP: {rendezvous}",
                "hosts:",
                f"  - hostname: {vm_name}",
                "    interfaces:",
                "      - name: eno1",
                f"        macAddress: {host_mac}",
                "    networkConfig:",
                "      interfaces:",
                *iface_lines,
                *route_lines,
                *dns_lines,
                "",
            ]
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


