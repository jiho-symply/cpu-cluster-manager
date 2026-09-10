from __future__ import annotations

import hashlib
import hmac
import os
import secrets
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse, RedirectResponse, Response
from fastapi.templating import Jinja2Templates

from .ssh_client import Node, NodeSSH

APP_DIR = Path(__file__).resolve().parent
CLUSTER = os.environ.get("CLUSTER", "").strip()
NODES_SPEC = os.environ.get("NODES", "").strip()
SSH_USER = os.environ.get("SSH_USER", "ysadmin").strip() or "ysadmin"
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
GRAFANA_BASE_URL = os.environ.get("GRAFANA_BASE_URL", "/grafana").rstrip("/") or "/grafana"
SESSION_COOKIE = "ccm_session"
SESSION_TTL_SECONDS = 12 * 60 * 60

if not CLUSTER:
    raise RuntimeError("CLUSTER must be set")
if not NODES_SPEC:
    raise RuntimeError("NODES must be set")
if not ADMIN_PASSWORD:
    raise RuntimeError("ADMIN_PASSWORD must be set")

SESSION_KEY = hashlib.sha256(("cpu-cluster-manager:" + ADMIN_PASSWORD).encode()).digest()

app = FastAPI(title="CPU Cluster Manager", docs_url=None, redoc_url=None)
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


def _session_signature(timestamp: str) -> str:
    return hmac.new(SESSION_KEY, timestamp.encode(), hashlib.sha256).hexdigest()


def issue_session() -> str:
    timestamp = str(int(time.time()))
    return f"{timestamp}.{_session_signature(timestamp)}"


def session_valid(request: Request) -> bool:
    token = request.cookies.get(SESSION_COOKIE, "")
    try:
        timestamp, signature = token.split(".", 1)
        issued_at = int(timestamp)
    except (ValueError, TypeError):
        return False
    age = int(time.time()) - issued_at
    if age < 0 or age > SESSION_TTL_SECONDS:
        return False
    return secrets.compare_digest(signature, _session_signature(timestamp))


def require_admin(request: Request) -> str:
    if not session_valid(request):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Authentication required")
    return "admin"


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


@app.get("/auth/check")
def auth_check(request: Request) -> Response:
    return Response(status_code=204 if session_valid(request) else 401)


@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request):
    if session_valid(request):
        return RedirectResponse(url="/", status_code=303)
    return templates.TemplateResponse(request=request, name="login.html", context={"cluster": CLUSTER})


@app.post("/api/login")
async def login(request: Request) -> JSONResponse:
    try:
        payload = await request.json()
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Invalid request") from exc
    password = str(payload.get("password", ""))
    if not secrets.compare_digest(password.encode(), ADMIN_PASSWORD.encode()):
        raise HTTPException(status_code=401, detail="Invalid password")
    response = JSONResponse({"ok": True})
    response.set_cookie(
        key=SESSION_COOKIE,
        value=issue_session(),
        max_age=SESSION_TTL_SECONDS,
        httponly=True,
        samesite="strict",
        path="/",
    )
    return response


@app.post("/logout")
def logout() -> RedirectResponse:
    response = RedirectResponse(url="/login", status_code=303)
    response.delete_cookie(SESSION_COOKIE, path="/")
    return response


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    if not session_valid(request):
        return RedirectResponse(url="/login", status_code=303)
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
