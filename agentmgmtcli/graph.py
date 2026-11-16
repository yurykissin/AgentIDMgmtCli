from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any

import httpx

from .models import AgentIdentity, AgentRegistration, Blueprint, PermissionGrant

AGENT_X_APP_ID = "59eca866-2f46-40b8-96ff-63f663121ef9"


class GraphError(RuntimeError):
    def __init__(self, status_code: int, message: str, payload: Any | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.payload = payload


class GraphClient:
    def __init__(self, token: str) -> None:
        self._token = token
        self._base = "https://graph.microsoft.com"
        self._http = httpx.Client(timeout=30)

    def close(self) -> None:
        self._http.close()

    def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, str] | None = None,
        body: dict[str, Any] | None = None,
        api_version: str = "v1.0",
        expected: tuple[int, ...] = (200,),
    ) -> dict[str, Any]:
        url = f"{self._base}/{api_version}{path}"
        headers = {"Authorization": f"Bearer {self._token}"}
        if body is not None:
            headers["Content-Type"] = "application/json"
            headers["OData-Version"] = "4.0"
        response = self._http.request(method, url, params=params, json=body, headers=headers)
        if response.status_code not in expected:
            raw = response.text
            try:
                payload = response.json()
            except ValueError:
                payload = None
            raise GraphError(response.status_code, raw, payload)
        if response.status_code == 204 or not response.text.strip():
            return {}
        return response.json()

    def current_user_id(self) -> str:
        data = self._request("GET", "/me", params={"$select": "id"})
        return str(data["id"])

    def list_blueprints(self) -> list[Blueprint]:
        data = self._request(
            "GET",
            "/applications/microsoft.graph.agentIdentityBlueprint",
            params={"$select": "id,appId,displayName,createdDateTime"},
        )
        return [
            Blueprint(
                id=item["id"],
                app_id=item.get("appId", ""),
                display_name=item.get("displayName", ""),
                created=item.get("createdDateTime"),
            )
            for item in data.get("value", [])
        ]

    def get_blueprint(self, object_id: str) -> Blueprint:
        item = self._request(
            "GET",
            f"/applications/{object_id}/microsoft.graph.agentIdentityBlueprint",
            params={"$select": "id,appId,displayName,createdDateTime"},
        )
        return Blueprint(
            id=item["id"],
            app_id=item.get("appId", ""),
            display_name=item.get("displayName", ""),
            created=item.get("createdDateTime"),
        )

    def resolve_blueprint(self, value: str) -> Blueprint:
        blueprints = self.list_blueprints()
        by_id = {b.id.lower(): b for b in blueprints}
        by_app = {b.app_id.lower(): b for b in blueprints}
        key = value.lower()
        if key in by_id:
            return by_id[key]
        if key in by_app:
            return by_app[key]
        exact_name = [b for b in blueprints if b.display_name.lower() == key]
        if len(exact_name) == 1:
            return exact_name[0]
        if not exact_name:
            raise ValueError(f"blueprint not found: {value}")
        raise ValueError(f"multiple blueprints match: {value}")

    def create_blueprint(self, display_name: str, sponsor_object_id: str) -> Blueprint:
        payload = {
            "displayName": display_name,
            "sponsors@odata.bind": [
                f"https://graph.microsoft.com/v1.0/users/{sponsor_object_id}",
            ],
        }
        item = self._request(
            "POST",
            "/applications/microsoft.graph.agentIdentityBlueprint",
            body=payload,
            expected=(201,),
        )
        return Blueprint(
            id=item["id"],
            app_id=item.get("appId", ""),
            display_name=item.get("displayName", display_name),
            created=item.get("createdDateTime"),
        )

    def create_blueprint_principal(self, blueprint_app_id: str) -> dict[str, Any]:
        return self._request(
            "POST",
            "/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal",
            body={"appId": blueprint_app_id},
            expected=(201,),
        )

    def list_identities(self) -> list[AgentIdentity]:
        data = self._request(
            "GET",
            "/servicePrincipals/microsoft.graph.agentIdentity",
            params={
                "$select": "id,appId,displayName,accountEnabled,sponsorIds",
                "$expand": "agentIdentityBlueprint($select=id)",
            },
        )
        identities: list[AgentIdentity] = []
        for item in data.get("value", []):
            bp = item.get("agentIdentityBlueprint") or {}
            identities.append(
                AgentIdentity(
                    id=item["id"],
                    app_id=item.get("appId", ""),
                    display_name=item.get("displayName", ""),
                    account_enabled=item.get("accountEnabled"),
                    blueprint_id=bp.get("id"),
                    sponsor_ids=list(item.get("sponsorIds") or []),
                )
            )
        return identities

    def resolve_identity(self, value: str) -> AgentIdentity:
        identities = self.list_identities()
        key = value.lower()
        for identity in identities:
            if identity.id.lower() == key or identity.app_id.lower() == key:
                return identity
        exact_name = [i for i in identities if i.display_name.lower() == key]
        if len(exact_name) == 1:
            return exact_name[0]
        if not exact_name:
            raise ValueError(f"agent identity not found: {value}")
        raise ValueError(f"multiple identities match: {value}")

    def create_identity(
        self,
        display_name: str,
        blueprint_id: str,
        sponsor_object_id: str,
    ) -> AgentIdentity:
        payload = {
            "displayName": display_name,
            "agentIdentityBlueprintId": blueprint_id,
            "sponsors@odata.bind": [
                f"https://graph.microsoft.com/v1.0/users/{sponsor_object_id}",
            ],
        }
        item = self._request(
            "POST",
            "/servicePrincipals/microsoft.graph.agentIdentity",
            body=payload,
            expected=(201,),
        )
        return AgentIdentity(
            id=item["id"],
            app_id=item.get("appId", ""),
            display_name=item.get("displayName", display_name),
            account_enabled=item.get("accountEnabled"),
            blueprint_id=blueprint_id,
            sponsor_ids=list(item.get("sponsorIds") or []),
        )

    def list_registrations(self) -> list[AgentRegistration]:
        data = self._request("GET", "/copilot/agentRegistrations", api_version="beta")
        regs: list[AgentRegistration] = []
        for item in data.get("value", []):
            regs.append(
                AgentRegistration(
                    id=item.get("id", ""),
                    display_name=item.get("displayName", ""),
                    blueprint_id=item.get("agentIdentityBlueprintId"),
                    agent_identity_id=item.get("agentIdentityId"),
                    source_agent_id=item.get("sourceAgentId"),
                    managed_by_app_id=item.get("managedByAppId"),
                )
            )
        return regs

    def register_agent(
        self,
        *,
        display_name: str,
        blueprint_id: str,
        agent_identity_id: str,
        owner_id: str,
        description: str | None = None,
    ) -> AgentRegistration:
        now = datetime.now(timezone.utc).isoformat()
        payload: dict[str, Any] = {
            "id": str(uuid.uuid4()),
            "displayName": display_name,
            "ownerIds": [owner_id],
            "createdBy": owner_id,
            "sourceCreatedDateTime": now,
            "sourceLastModifiedDateTime": now,
            "agentIdentityBlueprintId": blueprint_id,
            "agentIdentityId": agent_identity_id,
            "sourceAgentId": agent_identity_id,
            "managedByAppId": AGENT_X_APP_ID,
        }
        if description:
            payload["description"] = description
        item = self._request(
            "POST",
            "/copilot/agentRegistrations",
            api_version="beta",
            body=payload,
            expected=(201,),
        )
        return AgentRegistration(
            id=item.get("id", payload["id"]),
            display_name=item.get("displayName", display_name),
            blueprint_id=item.get("agentIdentityBlueprintId"),
            agent_identity_id=item.get("agentIdentityId"),
            source_agent_id=item.get("sourceAgentId"),
            managed_by_app_id=item.get("managedByAppId"),
        )

    def delete_blueprint(self, blueprint_object_id: str) -> None:
        self._request(
            "DELETE",
            f"/applications/{blueprint_object_id}/microsoft.graph.agentIdentityBlueprint",
            expected=(204,),
        )

    def delete_identity(self, identity_object_id: str) -> None:
        self._request(
            "DELETE",
            f"/servicePrincipals/{identity_object_id}/microsoft.graph.agentIdentity",
            expected=(204,),
        )

    def delete_registration(self, registration_id: str) -> None:
        self._request(
            "DELETE",
            f"/copilot/agentRegistrations/{registration_id}",
            api_version="beta",
            expected=(204,),
        )

    def delegated_grants_for_service_principal(self, service_principal_id: str) -> list[PermissionGrant]:
        data = self._request(
            "GET",
            "/oauth2PermissionGrants",
            params={"$filter": f"clientId eq '{service_principal_id}'"},
        )
        grants: list[PermissionGrant] = []
        for item in data.get("value", []):
            grants.append(
                PermissionGrant(
                    permission_type="delegated",
                    resource_id=item.get("resourceId", ""),
                    scope_or_role=item.get("scope", ""),
                    raw=item,
                )
            )
        return grants

    def app_role_assignments_for_service_principal(self, service_principal_id: str) -> list[PermissionGrant]:
        data = self._request(
            "GET",
            f"/servicePrincipals/{service_principal_id}/appRoleAssignments",
            params={"$select": "id,resourceId,appRoleId,principalId"},
        )
        grants: list[PermissionGrant] = []
        for item in data.get("value", []):
            grants.append(
                PermissionGrant(
                    permission_type="application",
                    resource_id=item.get("resourceId", ""),
                    scope_or_role=item.get("appRoleId", ""),
                    raw=item,
                )
            )
        return grants

    def get_service_principal_by_app_id(self, app_id: str) -> dict[str, Any] | None:
        data = self._request(
            "GET",
            "/servicePrincipals",
            params={"$filter": f"appId eq '{app_id}'", "$select": "id,appId,displayName"},
        )
        values = data.get("value", [])
        return values[0] if values else None

