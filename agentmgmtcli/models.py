from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(slots=True)
class Blueprint:
    id: str
    app_id: str
    display_name: str
    created: str | None = None


@dataclass(slots=True)
class AgentIdentity:
    id: str
    app_id: str
    display_name: str
    account_enabled: bool | None = None
    blueprint_id: str | None = None
    sponsor_ids: list[str] = field(default_factory=list)


@dataclass(slots=True)
class AgentRegistration:
    id: str
    display_name: str
    blueprint_id: str | None = None
    agent_identity_id: str | None = None
    source_agent_id: str | None = None
    managed_by_app_id: str | None = None


@dataclass(slots=True)
class PermissionGrant:
    permission_type: str
    resource_id: str
    scope_or_role: str
    raw: dict[str, Any]

