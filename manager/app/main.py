from __future__ import annotations

import os
import secrets
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.templating import Jinja2Templates

from .ssh_client import Node, NodeSSH

APP_DIR = Path(__file__).resolve().parent
CLUSTER = os.environ.get("CLUSTER", "").strip()
NODES_SPEC = os.environ.get("NODES", "").strip()
SSH_USER = os.environ.get("SSH_USER", "ysadmin").strip() or "ysadmin"
ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME", "")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
GRAFANA_BASE_URL = os.environ.get("GRAFANA_BASE_URL", "http://127.0.0.1:3000").rstrip("/")

if not CLUSTER:
    raise RuntimeError("CLUSTER must be set")
if not NODES_SPEC:
    raise RuntimeError("NODES must be set")
if not ADMIN_USERNAME or not ADMIN_PASSWORD:
    raise RuntimeError("ADMIN_USERNAME and ADMIN_PASSWORD must be set")

app = FastAPI(title="CPU Cluster Manager", docs_url=None, redoc_url=None)
security = HTTPBasic()
templates = Jinja2Templates(directory=str(APP_DIR / "templates"))


def parse_nodes(spec: str) -> list[Node]:
    nodes: list[Node] = []
    seen: set[str] = set()
    for raw in spec.split(","):
        entry = raw.strip()
        if not entry:
            continue
        if "@" not in entry:
            raise RuntimeError(f"invalid NODES entry: {entry!r}; expected name@host")
        name, endpoint = entry.split("@", 1)
        name = name.strip()
        endpoint = endpoint.strip()
        if not name or not endpoint:
            raise RuntimeError(f"invalid NODES entry: {entry!r}")
        if name in seen:
            raise RuntimeError(f"duplicate node name: {name}")
        seen.add(name)

        host = endpoint
        port = 22
        if endpoint.count(":") == 1:
            maybe_host, maybe_port = endpoint.rsplit(":", 1)
            if maybe_port.isdigit():
                host = maybe_host
                port = int(maybe_port)
        nodes.append(Node(name=name, host=host, port=port, user=SSH_USER))

    if not nodes:
        raise RuntimeError("NODES contains no valid compute nodes")
    return nodes


NODES = parse_nodes(NODES_SPEC)


def require_admin(credentials: HTTPBasicCredentials = Depends(security)) -> str:
    user_ok = secrets.compare_digest(credentials.username.encode(), ADMIN_USERNAME.encode())
    password_ok = secrets.compare_digest(credentials.password.encode(), ADMIN_PASSWORD.encode())
    if not (user_ok and password_ok):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid credentials",
            headers={"WWW-Authenticate": "Basic"},
        )
    return credentials.username


def get_node(name: str) -> Node:
    for node in NODES:
        if node.name == name:
            return node
    raise HTTPException(status_code=404, detail=f"Unknown node: {name}")


def collect_summary(node: Node) -> dict[str, str | bool | int]:
    try:
        data = NodeSSH(node).summary()
        return {"name": node.name, "host": node.host, "port": node.port, "reachable": True, **data}
    except Exception as exc:
        return {
            "name": node.name,
            "host": node.host,
            "port": node.port,
            "reachable": False,
            "error": str(exc),
        }


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/", response_class=HTMLResponse)
def index(request: Request, _: str = Depends(require_admin)):
    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={
            "cluster": CLUSTER,
            "node_count": len(NODES),
            "grafana_base_url": GRAFANA_BASE_URL,
        },
    )


@app.get("/api/nodes")
def api_nodes(_: str = Depends(require_admin)) -> JSONResponse:
    results: list[dict] = []
    with ThreadPoolExecutor(max_workers=min(8, max(1, len(NODES)))) as pool:
        futures = {pool.submit(collect_summary, node): node for node in NODES}
        for future in as_completed(futures):
            results.append(future.result())

    order = {node.name: i for i, node in enumerate(NODES)}
    results.sort(key=lambda item: order.get(str(item["name"]), 9999))
    return JSONResponse({"cluster": CLUSTER, "nodes": results})


@app.post("/api/nodes/{name}/{action}")
def node_action(name: str, action: str, _: str = Depends(require_admin)) -> JSONResponse:
    allowed = {"start", "stop", "restart", "recreate", "reset-password"}
    if action not in allowed:
        raise HTTPException(status_code=400, detail=f"Unsupported action: {action}")

    node = get_node(name)
    try:
        output = NodeSSH(node).action(action)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return JSONResponse({"ok": True, "node": name, "action": action, "output": output})


@app.get("/api/nodes/{name}/logs", response_class=PlainTextResponse)
def node_logs(name: str, _: str = Depends(require_admin)) -> PlainTextResponse:
    node = get_node(name)
    try:
        output = NodeSSH(node).logs()
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return PlainTextResponse(output)
