from __future__ import annotations

import os
import secrets
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import yaml
from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.templating import Jinja2Templates

from .ssh_client import Node, NodeSSH

APP_DIR = Path(__file__).resolve().parent
NODES_CONFIG = Path(os.environ.get("NODES_CONFIG", "/app/config/nodes.yaml"))
ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME", "")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")

if not ADMIN_USERNAME or not ADMIN_PASSWORD:
    raise RuntimeError("ADMIN_USERNAME and ADMIN_PASSWORD must be set")

app = FastAPI(title="CPU Cluster Manager", docs_url=None, redoc_url=None)
security = HTTPBasic()
templates = Jinja2Templates(directory=str(APP_DIR / "templates"))


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


def load_nodes() -> tuple[str, list[Node]]:
    try:
        raw = yaml.safe_load(NODES_CONFIG.read_text(encoding="utf-8")) or {}
    except FileNotFoundError as exc:
        raise RuntimeError(f"nodes config not found: {NODES_CONFIG}") from exc

    cluster = str(raw.get("cluster", "cluster1"))
    default_user = str(raw.get("ssh_user", "ysadmin"))
    nodes = [
        Node(
            name=str(item["name"]),
            host=str(item["host"]),
            port=int(item.get("port", 22)),
            user=str(item.get("user", default_user)),
        )
        for item in raw.get("nodes", [])
    ]
    return cluster, nodes


def get_node(name: str) -> Node:
    _, nodes = load_nodes()
    for node in nodes:
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
    cluster, nodes = load_nodes()
    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={"cluster": cluster, "node_count": len(nodes)},
    )


@app.get("/api/nodes")
def api_nodes(_: str = Depends(require_admin)) -> JSONResponse:
    cluster, nodes = load_nodes()
    results: list[dict] = []
    with ThreadPoolExecutor(max_workers=min(8, max(1, len(nodes)))) as pool:
        futures = {pool.submit(collect_summary, node): node for node in nodes}
        for future in as_completed(futures):
            results.append(future.result())

    order = {node.name: i for i, node in enumerate(nodes)}
    results.sort(key=lambda item: order.get(str(item["name"]), 9999))
    return JSONResponse({"cluster": cluster, "nodes": results})


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
