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
        # A positive TCP connection to either host-native service is sufficient
        # to prove the host is not yet powered off. A failed connection alone is
        # not evidence of a completed shutdown.
        for port in (self.node.port, 9100):
            try:
                with socket.create_connection((self.node.host, port), timeout=timeout):
                    return True
            except OSError:
                continue
        return False

    def wait_offline(self, timeout: int = 60, interval: float = 2.0, consecutive_failures: int = 3) -> bool:
        deadline = time.monotonic() + timeout
        misses = 0
        while time.monotonic() < deadline:
            misses = 0 if self.is_online() else misses + 1
            if misses >= consecutive_failures:
                return True
            pause = min(interval, max(0.0, deadline - time.monotonic()))
            if pause > 0:
                time.sleep(pause)
        return False

    def summary(self) -> dict[str, str]:
        return self._parse_kv(self._run("summary"))

    def action(self, action: str) -> str:
        # `poweroff` is retained for the cluster-wide safe shutdown workflow;
        # the browser-facing individual-node API exposes reboot instead.
        if action not in {"start", "stop", "restart", "recreate", "reset-password", "reset", "reboot", "poweroff"}:
            raise ValueError(f"unsupported action: {action}")
        if action == "reset":
            timeout = 90
        elif action in {"recreate", "reboot", "poweroff"}:
            timeout = 45
        else:
            timeout = 40
        return self._run(action, timeout=timeout)

    def poweroff_and_wait(self, timeout: int = 60) -> dict[str, str | bool]:
        # An already unreachable host is NOT implicitly confirmed powered off.
        # Require an acknowledged poweroff request, then repeated observations.
        output = self.action("poweroff")
        if "POWER_OFF_REQUESTED=1" not in output:
            raise RuntimeError(f"{self.node.name}: poweroff request was not acknowledged")
        offline = self.wait_offline(timeout=timeout)
        return {
            "node": self.node.name,
            "ok": offline,
            "offline": offline,
            "detail": output if offline else "poweroff acknowledged but host SSH/metrics ports did not remain unreachable",
        }

    def logs(self) -> str:
        return self._run("logs", timeout=15)
