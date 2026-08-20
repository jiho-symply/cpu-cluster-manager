from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass

SSH_KEY = os.environ.get("SSH_KEY", "/run/ssh/id_ed25519")
SSH_KNOWN_HOSTS = os.environ.get("SSH_KNOWN_HOSTS", "/run/ssh/known_hosts")
REMOTE_ADMIN = "/usr/local/sbin/cluster-node-admin"


@dataclass(frozen=True)
class Node:
    name: str
    host: str
    port: int = 22
    user: str = "cluster-ui"


class NodeSSH:
    def __init__(self, node: Node):
        self.node = node

    def _run(self, action: str, timeout: int = 12) -> str:
        cmd = [
            "ssh",
            "-i",
            SSH_KEY,
            "-p",
            str(self.node.port),
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=4",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            f"UserKnownHostsFile={SSH_KNOWN_HOSTS}",
            f"{self.node.user}@{self.node.host}",
            "sudo",
            REMOTE_ADMIN,
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

    def summary(self) -> dict[str, str]:
        return self._parse_kv(self._run("summary"))

    def action(self, action: str) -> str:
        if action not in {"start", "stop", "restart", "recreate", "reset-password"}:
            raise ValueError(f"unsupported action: {action}")
        return self._run(action, timeout=40)

    def logs(self) -> str:
        return self._run("logs", timeout=15)
