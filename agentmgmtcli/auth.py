from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from typing import Any


class AuthError(RuntimeError):
    pass


@dataclass(slots=True)
class AzContext:
    tenant_id: str
    user_name: str
    subscription_id: str | None


class AzTokenProvider:
    def __init__(self, tenant_id: str | None = None) -> None:
        self._tenant_id_override = tenant_id

    def _run_az(self, *args: str) -> dict[str, Any]:
        proc = subprocess.run(
            ["az", *args, "-o", "json"],
            check=False,
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            raise AuthError(proc.stderr.strip() or proc.stdout.strip() or "az command failed")
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            raise AuthError(f"failed to parse az output: {exc}") from exc

    def account_context(self) -> AzContext:
        data = self._run_az("account", "show")
        user = data.get("user") or {}
        return AzContext(
            tenant_id=data.get("tenantId", ""),
            user_name=user.get("name", ""),
            subscription_id=data.get("id"),
        )

    def get_graph_token(self) -> str:
        args = ["account", "get-access-token", "--resource", "https://graph.microsoft.com/"]
        if self._tenant_id_override:
            args.extend(["--tenant", self._tenant_id_override])
        data = self._run_az(*args)
        token = data.get("accessToken")
        if not token:
            raise AuthError("az did not return an access token")
        return str(token)

