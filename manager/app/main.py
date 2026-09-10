from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import socket
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import quote

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse, RedirectResponse, Response
from fastapi.templating import Jinja2Templates

from .ssh_client import Node, NodeSSH

APP_DIR = Path(__file__).resolve().parent
CLUSTER = os.environ.get("CLUSTER", "").strip()
NODES_SPEC = os.environ.get("NODES", "").strip()
SSH_USER = os.environ.get("SSH_USER", "ysadmin").strip() or "ysadmin"
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
PEER_CLUSTER = os.environ.get("PEER_CLUSTER", "").strip()
PEER_URL = os.environ.get("PEER_URL", "").strip().rstrip("/")
MASTER_CONTROL_SOCKET = os.environ.get("MASTER_CONTROL_SOCKET", "/run/master-control.sock")
SESSION_COOKIE = "ccm_session"
SESSION_TTL_SECONDS = 12 * 60 * 60
PEER_HEADER = "X-CCM-Peer-Token"

if not CLUSTER:
    raise RuntimeError("CLUSTER must be set")
if not NODES_SPEC:
    raise RuntimeError("NODES must be set")
if not ADMIN_PASSWORD:
    raise RuntimeError("ADMIN_PASSWORD must be set")
if PEER_URL and not PEER_CLUSTER:
    raise RuntimeError("PEER_CLUSTER must be set when PEER_URL is configured")

SESSION_KEY = hashlib.sha256(("cpu-cluster-manager:" + ADMIN_PASSWORD).encode()).digest()

app = FastAPI(title="CPU Cluster Manager", docs_url=None, redoc_url=None)
templates = Jinja2Templates(directory=str(APP_DIR / "templates"))

_shutdown_lock = threading.Lock()
_shutdown_confirmed: set[str] = set()


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


def peer_valid(request: Request) -> bool:
    token = request.headers.get(PEER_HEADER, "")
    return bool(token) and secrets.compare_digest(token.encode(), ADMIN_PASSWORD.encode())


def request_authenticated(request: Request) -> bool:
    return session_valid(request) or peer_valid(request)


def require_admin(request: Request) -> str:
    if not request_authenticated(request):
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


def collect_local_nodes() -> list[dict]:
    results: list[dict] = []
    with ThreadPoolExecutor(max_workers=min(8, max(1, len(NODES)))) as pool:
        futures = {pool.submit(collect_summary, node): node for node in NODES}
        for future in as_completed(futures):
            results.append(future.result())
    order = {node.name: i for i, node in enumerate(NODES)}
    results.sort(key=lambda item: order.get(str(item["name"]), 9999))
    return results


def local_cluster_payload() -> dict:
    return {
        "cluster": CLUSTER,
        "reachable": True,
        "local": True,
        "grafana_base": f"/{CLUSTER}/grafana",
        "nodes": collect_local_nodes(),
    }


def _peer_json(path: str, method: str = "GET", timeout: int = 15) -> dict:
    if not PEER_URL:
        raise RuntimeError("peer cluster is not configured")
    url = f"{PEER_URL}{path}"
    data = b"" if method != "GET" else None
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"Accept": "application/json", PEER_HEADER: ADMIN_PASSWORD},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{PEER_CLUSTER}: HTTP {exc.code}: {detail}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError(f"{PEER_CLUSTER}: {exc}") from exc
    return json.loads(payload) if payload else {}


def _cluster_is_local(cluster: str) -> bool:
    if cluster == CLUSTER:
        return True
    if PEER_URL and cluster == PEER_CLUSTER:
        return False
    raise HTTPException(status_code=404, detail=f"Unknown cluster: {cluster}")


def _mark_shutdown_confirmed(name: str, confirmed: bool) -> None:
    with _shutdown_lock:
        if confirmed:
            _shutdown_confirmed.add(name)
        else:
            _shutdown_confirmed.discard(name)


def _shutdown_one(node: Node) -> dict:
    try:
        result = NodeSSH(node).poweroff_and_wait(timeout=60)
        if bool(result.get("offline")):
            _mark_shutdown_confirmed(node.name, True)
        return result
    except Exception as exc:
        _mark_shutdown_confirmed(node.name, False)
        return {"node": node.name, "ok": False, "offline": False, "detail": str(exc)}


def shutdown_local_computes() -> dict:
    results: list[dict] = []
    with ThreadPoolExecutor(max_workers=min(8, max(1, len(NODES)))) as pool:
        futures = {pool.submit(_shutdown_one, node): node for node in NODES}
        for future in as_completed(futures):
            results.append(future.result())
    order = {node.name: i for i, node in enumerate(NODES)}
    results.sort(key=lambda item: order.get(str(item["node"]), 9999))
    all_offline = all(bool(item.get("offline")) for item in results)
    return {"ok": all_offline, "cluster": CLUSTER, "all_offline": all_offline, "nodes": results}


def master_shutdown_state() -> dict:
    online: list[str] = []
    for node in NODES:
        if NodeSSH(node).is_online(timeout=1.0):
            online.append(node.name)
    with _shutdown_lock:
        unconfirmed = [node.name for node in NODES if node.name not in _shutdown_confirmed]
    return {
        "ready": not online and not unconfirmed,
        "online": online,
        "unconfirmed": unconfirmed,
    }


def master_control(action: str) -> str:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(4)
    try:
        sock.connect(MASTER_CONTROL_SOCKET)
        sock.sendall((action + "\n").encode())
        chunks = bytearray()
        while b"\n" not in chunks and len(chunks) < 4096:
            chunk = sock.recv(1024)
            if not chunk:
                break
            chunks.extend(chunk)
        return bytes(chunks).decode("utf-8", errors="replace").strip()
    except OSError as exc:
        raise RuntimeError(f"master control socket failed: {exc}") from exc
    finally:
        sock.close()


def parse_reset_credential(output: str) -> dict[str, str]:
    credential: dict[str, str] = {}
    for line in output.splitlines():
        if line.startswith("[CREDENTIAL] username="):
            credential["username"] = line.split("=", 1)[1].strip()
        elif line.startswith("[CREDENTIAL] temporary_password="):
            credential["password"] = line.split("=", 1)[1].strip()
    return credential


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/auth/check")
def auth_check(request: Request) -> Response:
    return Response(status_code=204 if request_authenticated(request) else 401)


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
        context={"cluster": CLUSTER, "federated": bool(PEER_URL)},
    )


@app.get("/api/nodes")
def api_nodes(_: str = Depends(require_admin)) -> JSONResponse:
    return JSONResponse({"cluster": CLUSTER, "nodes": collect_local_nodes()})


@app.post("/api/nodes/{name}/{action}")
def node_action(name: str, action: str, _: str = Depends(require_admin)) -> JSONResponse:
    # Individual host poweroff is intentionally not exposed. Cluster-wide
    # shutdown still uses the private _shutdown_one()/poweroff path.
    allowed = {"start", "stop", "restart", "recreate", "reset-password", "reset", "reboot"}
    if action not in allowed:
        raise HTTPException(status_code=400, detail=f"Unsupported action: {action}")

    node = get_node(name)
    try:
        output = NodeSSH(node).action(action)
        _mark_shutdown_confirmed(name, False)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    payload: dict[str, object] = {"ok": True, "node": name, "action": action, "output": output}
    if action in {"reset-password", "reset"}:
        credential = parse_reset_credential(output)
        if not credential.get("username") or not credential.get("password"):
            raise HTTPException(status_code=502, detail=f"{action} succeeded but credential output was incomplete")
        payload["credential"] = credential
    return JSONResponse(payload)


@app.get("/api/nodes/{name}/logs", response_class=PlainTextResponse)
def node_logs(name: str, _: str = Depends(require_admin)) -> PlainTextResponse:
    node = get_node(name)
    try:
        output = NodeSSH(node).logs()
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return PlainTextResponse(output)


@app.post("/api/shutdown/computes")
def api_shutdown_computes(_: str = Depends(require_admin)) -> JSONResponse:
    return JSONResponse(shutdown_local_computes())


@app.get("/api/shutdown/state")
def api_shutdown_state(_: str = Depends(require_admin)) -> JSONResponse:
    return JSONResponse({"cluster": CLUSTER, **master_shutdown_state()})


@app.post("/api/shutdown/master")
def api_shutdown_master(_: str = Depends(require_admin)) -> JSONResponse:
    state = master_shutdown_state()
    if not state["ready"]:
        raise HTTPException(
            status_code=409,
            detail={
                "message": "all compute nodes must be confirmed offline before master shutdown",
                **state,
            },
        )
    try:
        output = master_control("poweroff")
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return JSONResponse({"ok": True, "cluster": CLUSTER, "poweroff_requested": True, "output": output})


@app.get("/api/clusters")
def api_clusters(_: str = Depends(require_admin)) -> JSONResponse:
    clusters = [local_cluster_payload()]
    if PEER_URL:
        try:
            peer = _peer_json("/api/nodes", timeout=15)
            clusters.append(
                {
                    "cluster": str(peer.get("cluster") or PEER_CLUSTER),
                    "reachable": True,
                    "local": False,
                    "grafana_base": f"/{PEER_CLUSTER}/grafana",
                    "nodes": list(peer.get("nodes") or []),
                }
            )
        except Exception as exc:
            clusters.append(
                {
                    "cluster": PEER_CLUSTER,
                    "reachable": False,
                    "local": False,
                    "grafana_base": f"/{PEER_CLUSTER}/grafana",
                    "nodes": [],
                    "error": str(exc),
                }
            )
    return JSONResponse({"primary": CLUSTER, "federated": bool(PEER_URL), "clusters": clusters})


@app.post("/api/clusters/{cluster}/nodes/{name}/{action}")
def cluster_node_action(cluster: str, name: str, action: str, _: str = Depends(require_admin)) -> JSONResponse:
    if _cluster_is_local(cluster):
        return node_action(name, action, "admin")
    try:
        payload = _peer_json(
            f"/api/nodes/{quote(name, safe='')}/{quote(action, safe='')}",
            method="POST",
            timeout=100 if action == "reset" else 45,
        )
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return JSONResponse(payload)


@app.get("/api/clusters/{cluster}/nodes/{name}/logs", response_class=PlainTextResponse)
def cluster_node_logs(cluster: str, name: str, _: str = Depends(require_admin)) -> PlainTextResponse:
    if _cluster_is_local(cluster):
        return node_logs(name, "admin")
    if not PEER_URL:
        raise HTTPException(status_code=404, detail="peer cluster is not configured")
    url = f"{PEER_URL}/api/nodes/{quote(name, safe='')}/logs"
    request = urllib.request.Request(url, headers={PEER_HEADER: ADMIN_PASSWORD})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return PlainTextResponse(response.read().decode("utf-8", errors="replace"))
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"{PEER_CLUSTER}: {exc}") from exc


@app.post("/api/clusters/{cluster}/shutdown/computes")
def cluster_shutdown_computes(cluster: str, _: str = Depends(require_admin)) -> JSONResponse:
    if _cluster_is_local(cluster):
        return JSONResponse(shutdown_local_computes())
    try:
        payload = _peer_json("/api/shutdown/computes", method="POST", timeout=90)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return JSONResponse(payload)


@app.get("/api/clusters/{cluster}/shutdown/state")
def cluster_shutdown_state(cluster: str, _: str = Depends(require_admin)) -> JSONResponse:
    if _cluster_is_local(cluster):
        return JSONResponse({"cluster": CLUSTER, **master_shutdown_state()})
    try:
        payload = _peer_json("/api/shutdown/state", timeout=15)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return JSONResponse(payload)


@app.post("/api/clusters/{cluster}/shutdown/master")
def cluster_shutdown_master(cluster: str, _: str = Depends(require_admin)) -> JSONResponse:
    if _cluster_is_local(cluster):
        return api_shutdown_master("admin")
    try:
        payload = _peer_json("/api/shutdown/master", method="POST", timeout=10)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return JSONResponse(payload)
