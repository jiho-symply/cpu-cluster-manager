from __future__ import annotations

import json
import os
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

PROMETHEUS_HOT_URL = os.environ.get("PROMETHEUS_HOT_URL", "http://prometheus-hot:9090").rstrip("/")

METRICS = {
    "cpu_percent": "100 * cluster_node_cpu_utilization_ratio",
    "memory_percent": "100 * cluster_node_memory_utilization_ratio",
    "disk_percent": "100 * cluster_node_disk_utilization_ratio_max",
}


def _query_vector(expr: str) -> dict[str, float]:
    query = urllib.parse.urlencode({"query": expr})
    url = f"{PROMETHEUS_HOT_URL}/api/v1/query?{query}"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=3) as response:
        payload = json.loads(response.read().decode("utf-8"))

    if payload.get("status") != "success":
        return {}

    result: dict[str, float] = {}
    for sample in payload.get("data", {}).get("result", []):
        node = str(sample.get("metric", {}).get("node", "")).strip()
        value = sample.get("value")
        if not node or not isinstance(value, list) or len(value) < 2:
            continue
        try:
            result[node] = float(value[1])
        except (TypeError, ValueError):
            continue
    return result


def collect_live_metrics() -> dict[str, dict[str, float]]:
    """Return current CPU/memory/disk percentages keyed by compute node.

    Prometheus is advisory for the control table. A temporary monitoring failure
    must not make SSH/container controls unavailable, so failed queries are
    ignored and the UI displays an em dash for the missing number.
    """
    by_node: dict[str, dict[str, float]] = {}
    with ThreadPoolExecutor(max_workers=len(METRICS)) as pool:
        futures = {pool.submit(_query_vector, expr): field for field, expr in METRICS.items()}
        for future in as_completed(futures):
            field = futures[future]
            try:
                values = future.result()
            except Exception:
                continue
            for node, value in values.items():
                by_node.setdefault(node, {})[field] = value
    return by_node
