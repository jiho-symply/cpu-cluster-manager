#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml


def main() -> None:
    config = Path(sys.argv[1] if len(sys.argv) > 1 else "config/nodes.yaml")
    output = Path(sys.argv[2] if len(sys.argv) > 2 else "monitoring/targets")
    if not config.is_file():
        raise SystemExit(f"nodes config not found: {config}")

    raw = yaml.safe_load(config.read_text(encoding="utf-8")) or {}
    cluster = str(raw.get("cluster", "cluster1"))
    platform = str(raw.get("platform", "unknown"))
    nodes = raw.get("nodes", [])
    if not nodes:
        raise SystemExit(f"no nodes found in {config}")

    targets = []
    for item in nodes:
        name = str(item.get("name", "")).strip()
        host = str(item.get("host", "")).strip()
        if not name or not host:
            raise SystemExit(f"invalid node entry in {config}: {item}")
        targets.append(
            {
                "targets": [f"{host}:9100"],
                "labels": {
                    "cluster": cluster,
                    "platform": platform,
                    "node": name,
                },
            }
        )

    output.mkdir(parents=True, exist_ok=True)
    (output / "node-exporter.json").write_text(
        json.dumps(targets, indent=2) + "\n", encoding="utf-8"
    )

    stale = output / "cadvisor.json"
    if stale.exists():
        stale.unlink()

    print(f"[OK] cluster={cluster} platform={platform}")
    print(f"[OK] monitoring targets: {output / 'node-exporter.json'}")
    for item in targets:
        print(f"  {item['labels']['node']}: {item['targets'][0]}")


if __name__ == "__main__":
    main()
