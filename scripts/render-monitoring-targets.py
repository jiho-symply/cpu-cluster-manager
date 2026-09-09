#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def parse_nodes(path: Path) -> list[dict[str, str]]:
    nodes: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("- name:"):
            if current:
                nodes.append(current)
            current = {"name": unquote(stripped.split(":", 1)[1])}
            continue
        if current is None:
            continue
        if stripped.startswith("host:"):
            current["host"] = unquote(stripped.split(":", 1)[1])
    if current:
        nodes.append(current)

    for node in nodes:
        if not node.get("name") or not node.get("host"):
            raise SystemExit(f"invalid node entry in {path}: {node}")
    if not nodes:
        raise SystemExit(f"no nodes found in {path}")
    return nodes


def main() -> None:
    config = Path(sys.argv[1] if len(sys.argv) > 1 else "config/nodes.yaml")
    output = Path(sys.argv[2] if len(sys.argv) > 2 else "monitoring/targets")
    if not config.is_file():
        raise SystemExit(f"nodes config not found: {config}")

    nodes = parse_nodes(config)
    output.mkdir(parents=True, exist_ok=True)
    node_exporter = [
        {"targets": [f"{n['host']}:9100"], "labels": {"node": n["name"]}}
        for n in nodes
    ]
    cadvisor = [
        {"targets": [f"{n['host']}:8081"], "labels": {"node": n["name"]}}
        for n in nodes
    ]
    (output / "node-exporter.json").write_text(json.dumps(node_exporter, indent=2) + "\n", encoding="utf-8")
    (output / "cadvisor.json").write_text(json.dumps(cadvisor, indent=2) + "\n", encoding="utf-8")

    print(f"[OK] monitoring targets: {output}")
    for node in nodes:
        print(f"  {node['name']}: {node['host']}:9100, {node['host']}:8081")


if __name__ == "__main__":
    main()
