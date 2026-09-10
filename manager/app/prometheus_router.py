from __future__ import annotations

import asyncio
import re
import urllib.error
import urllib.parse
import urllib.request

from fastapi import APIRouter, FastAPI, Request
from fastapi.responses import Response

router = APIRouter(prefix="/prometheus-auto")
app = FastAPI(title="CPU Cluster Prometheus Auto Router", docs_url=None, redoc_url=None)

HOT_URL = "http://prometheus-hot:9090"
ARCHIVE_URL = "http://prometheus-archive:9090"
ARCHIVE_STEP_SECONDS = 300.0

# The archive keeps min/avg/max envelopes. The unified dashboard uses the
# 5-minute average series when Grafana asks for >=5m resolution; min/max remain
# stored and available for diagnostics or future envelope panels.
ARCHIVE_METRIC_MAP = {
    "cluster_node_cpu_utilization_ratio": "archive_node_cpu_utilization_ratio_avg5m",
    "cluster_node_memory_utilization_ratio": "archive_node_memory_utilization_ratio_avg5m",
    "cluster_node_disk_utilization_ratio_max": "archive_node_disk_utilization_ratio_avg5m",
    "cluster_rent_cpu_cores": "archive_rent_cpu_cores_avg5m",
    "cluster_rent_memory_working_set_bytes": "archive_rent_memory_working_set_bytes_avg5m",
    "cluster_rent_running": "archive_rent_running_avg5m",
}

_DURATION_RE = re.compile(r"(?P<value>[0-9]+(?:\.[0-9]+)?)(?P<unit>ms|s|m|h|d|w|y)")
_UNIT_SECONDS = {
    "ms": 0.001,
    "s": 1.0,
    "m": 60.0,
    "h": 3600.0,
    "d": 86400.0,
    "w": 604800.0,
    "y": 31536000.0,
}


def _duration_seconds(raw: str) -> float:
    raw = raw.strip()
    if not raw:
        return 0.0
    try:
        return float(raw)
    except ValueError:
        pass

    pos = 0
    total = 0.0
    for match in _DURATION_RE.finditer(raw):
        if match.start() != pos:
            return 0.0
        total += float(match.group("value")) * _UNIT_SECONDS[match.group("unit")]
        pos = match.end()
    return total if pos == len(raw) else 0.0


def _rewrite_archive_query(query: str) -> str:
    # Metric names are PromQL identifiers; word-style boundaries around '_' are
    # not reliable, so use explicit identifier lookarounds.
    for hot, archive in ARCHIVE_METRIC_MAP.items():
        query = re.sub(rf"(?<![A-Za-z0-9_:]){re.escape(hot)}(?![A-Za-z0-9_:])", archive, query)
    return query


def _route_form(body: bytes, content_type: str, path: str) -> tuple[str, bytes]:
    if path != "api/v1/query_range" or "application/x-www-form-urlencoded" not in content_type:
        return HOT_URL, body

    try:
        params = urllib.parse.parse_qsl(body.decode("utf-8"), keep_blank_values=True)
    except UnicodeDecodeError:
        return HOT_URL, body

    step = 0.0
    for key, value in params:
        if key == "step":
            step = _duration_seconds(value)
            break

    if step < ARCHIVE_STEP_SECONDS:
        return HOT_URL, body

    rewritten = []
    for key, value in params:
        rewritten.append((key, _rewrite_archive_query(value) if key == "query" else value))
    return ARCHIVE_URL, urllib.parse.urlencode(rewritten).encode("utf-8")


def _proxy(method: str, url: str, body: bytes | None, content_type: str) -> tuple[int, bytes, str]:
    headers = {"Accept": "application/json"}
    if body is not None:
        headers["Content-Type"] = content_type or "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.status, response.read(), response.headers.get("Content-Type", "application/json")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(), exc.headers.get("Content-Type", "application/json")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        payload = (f'{{"status":"error","errorType":"proxy","error":"{str(exc)}"}}').encode()
        return 502, payload, "application/json"


@router.get("/healthz")
def healthz() -> dict[str, str | int]:
    return {"status": "ok", "archive_step_seconds": int(ARCHIVE_STEP_SECONDS)}


@router.api_route("/{path:path}", methods=["GET", "POST"])
async def prometheus_auto(path: str, request: Request) -> Response:
    method = request.method.upper()
    body = await request.body() if method == "POST" else None
    content_type = request.headers.get("content-type", "")

    backend = HOT_URL
    routed_body = body
    if body is not None:
        backend, routed_body = _route_form(body, content_type, path)

    query_string = request.url.query
    # Grafana normally POSTs query_range. Handle GET query_range as well.
    if method == "GET" and path == "api/v1/query_range":
        params = urllib.parse.parse_qsl(query_string, keep_blank_values=True)
        step = next((_duration_seconds(v) for k, v in params if k == "step"), 0.0)
        if step >= ARCHIVE_STEP_SECONDS:
            backend = ARCHIVE_URL
            params = [(k, _rewrite_archive_query(v) if k == "query" else v) for k, v in params]
            query_string = urllib.parse.urlencode(params)

    target = f"{backend}/{path}"
    if query_string:
        target += f"?{query_string}"

    status_code, payload, response_type = await asyncio.to_thread(
        _proxy, method, target, routed_body, content_type
    )
    return Response(content=payload, status_code=status_code, media_type=response_type.split(";", 1)[0])


app.include_router(router)
