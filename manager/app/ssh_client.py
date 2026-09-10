from __future__ import annotations

import os
import socket
import subprocess
import time
from dataclasses import dataclass

SSH_KEY = os.environ.get("SSH_KEY", "/run/ssh/id_ed25519")
SSH_KNOWN_HOSTS = os.environ.get("SSH_KNOWN_HOSTS", "/run/ssh/known_hosts")


@dataclass(frozen=True)
class Node:
    name: str
    host: str
    port: int = 22
    user: str = "ysadmin"


class NodeSSH:
    def __init__(self, node: Node):
        self.node = node

    def _run(self, action: str, timeout: int = 12) -> str:
        cmd = [
            "ssh",
            "-T",
            "-i",
            SSH_KEY,
            "-p",
            str(self.node.port),
            "-o",
            "BatchMode=yes",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "ConnectTimeout=4",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            f"UserKnownHostsFile={SSH_KNOWN_HOSTS}",
            f"{self.node.user}@{self.node.host}",
            action,
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or "SSH command failed").strip()
            raise RuntimeError(f"{self.node.name}: {detail}")
        return proc.stdout.strip()

    @staticmethod
    def _parse_kv(text: str) -> dict[str, str]:
        result: dict[str, str] = {}
        for line in text.splitlines():
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            result[key.strip().lower()] = value.strip()
        return result

    def is_online(self, timeout: float = 1.0) -> bool:
        try:
            with socket.create_connection((self.node.host, self.node.port), timeout=timeout):
                return True
        except OSError:
            return False

    def wait_offline(self, timeout: int = 60, interval: float = 2.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not self.is_online():
                return True
            time.sleep(interval)
        return not self.is_online()

    def summary(self) -> dict[str, str]:
        return self._parse_kv(self._run("summary"))

    def action(self, action: str) -> str:
        if action not in {"start", "stop", "restart", "recreate", "reset-password", "poweroff"}:
            raise ValueError(f"unsupported action: {action}")
        timeout = 45 if action in {"recreate", "poweroff"} else 40
        return self._run(action, timeout=timeout)

    def poweroff_and_wait(self, timeout: int = 60) -> dict[str, str | bool]:
        if not self.is_online():
            return {"node": self.node.name, "ok": True, "offline": True, "detail": "already offline"}
        output = self.action("poweroff")
        offline = self.wait_offline(timeout=timeout)
        return {
            "node": self.node.name,
            "ok": offline,
            "offline": offline,
            "detail": output if offline else "poweroff requested but SSH port remained reachable",
        }

    def logs(self) -> str:
        return self._run("logs", timeout=15)
