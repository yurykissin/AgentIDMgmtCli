from __future__ import annotations

import json
import sys
from dataclasses import asdict
from typing import Annotated

import typer
from rich.console import Console
from rich.table import Table

from .a365 import A365Error, create_with_a365
from .auth import AuthError, AzTokenProvider
from .graph import GraphClient, GraphError
from .models import AgentIdentity, AgentRegistration, Blueprint
from .treeview import build_tree

app = typer.Typer(help="Manage Agent ID blueprints, identities, and agent registry entries.")
create_app = typer.Typer(help="Create blueprints and identities.")
delete_app = typer.Typer(help="Delete one identity, one blueprint, or one registration.")
show_app = typer.Typer(help="Show an object and optionally its permissions.")
app.add_typer(create_app, name="create")
app.add_typer(delete_app, name="delete")
app.add_typer(show_app, name="show")

console = Console()


def _client(tenant_id: str | None) -> GraphClient:
    provider = AzTokenProvider(tenant_id=tenant_id)
    token = provider.get_graph_token()
    return GraphClient(token)


def _as_json(data: object) -> None:
    console.print_json(data=json.dumps(data, indent=2, default=str))


def _match_registration(registrations: list[AgentRegistration], value: str) -> AgentRegistration:
    key = value.lower()
    for reg in registrations:
        if reg.id.lower() == key or reg.display_name.lower() == key:
            return reg
    raise typer.BadParameter(f"registration not found: {value}")


def _confirm(required_name: str) -> None:
    typed = typer.prompt(f"Type exact name to confirm delete: {required_name}")
    if typed != required_name:
        raise typer.Abort()


def _permission_table(title: str, rows: list[tuple[str, str, str]]) -> Table:
    table = Table(title=title)
    table.add_column("Type")
    table.add_column("Resource ID")
    table.add_column("Scope or Role")
    for row in rows:
        table.add_row(*row)
    return table


def _show_permissions_for_sp(client: GraphClient, service_principal_id: str) -> None:
    delegated = client.delegated_grants_for_service_principal(service_principal_id)
    app_roles = client.app_role_assignments_for_service_principal(service_principal_id)

    rows = [
        (g.permission_type, g.resource_id, g.scope_or_role)
        for g in [*delegated, *app_roles]
    ]
    if not rows:
        console.print("[yellow]No permission grants found for this service principal.[/yellow]")
        return
    console.print(_permission_table("Permissions", rows))


@app.callback()
def main() -> None:
    """Agent management entrypoint."""


@app.command("tree")
def tree(
    tenant_id: Annotated[str | None, typer.Option("--tenant-id")] = None,
    output_json: Annotated[bool, typer.Option("--json")] = False,
) -> None:
    """Display blueprint -> identities -> registrations."""
    client = _client(tenant_id)
    try:
        blueprints = client.list_blueprints()
        identities = client.list_identities()
        registrations = client.list_registrations()
        if output_json:
            payload = {
                "blueprints": [asdict(b) for b in blueprints],
                "identities": [asdict(i) for i in identities],
                "registrations": [asdict(r) for r in registrations],
            }
            _as_json(payload)
            return
        console.print(build_tree(blueprints, identities, registrations))
    finally:
        client.close()


@show_app.command("blueprint")
def show_blueprint(
    selector: str,
    tenant_id: Annotated[str | None, typer.Option("--tenant-id")] = None,
    permissions: Annotated[bool, typer.Option("--permissions")] = False,
    output_json: Annotated[bool, typer.Option("--json")] = False,
) -> None:
    """Show one blueprint by object ID, app ID, or exact display name."""
    client = _client(tenant_id)
    try:
        blueprint = client.resolve_blueprint(selector)
        if output_json:
            _as_json(asdict(blueprint))
        else:
            table = Table(title="Blueprint")
            table.add_column("Field")
            table.add_column("Value")
            table.add_row("displayName", blueprint.display_name)
            table.add_row("objectId", blueprint.id)
            table.add_row("appId", blueprint.app_id)
            table.add_row("created", blueprint.created or "")
            console.print(table)

        if permissions:
            sp = client.get_service_principal_by_app_id(blueprint.app_id)
            if not sp:
                console.print("[yellow]No service principal found for blueprint appId.[/yellow]")
                return
            _show_permissions_for_sp(client, str(sp["id"]))
    finally:
        client.close()


@show_app.command("identity")
def show_identity(
    selector: str,
    tenant_id: Annotated[str | None, typer.Option("--tenant-id")] = None,
    permissions: Annotated[bool, typer.Option("--permissions")] = False,
    output_json: Annotated[bool, typer.Option("--json")] = False,
) -> None:
    """Show one identity by object ID, app ID, or exact display name."""
    client = _client(tenant_id)
    try:
        identity = client.resolve_identity(selector)
        if output_json:
            _as_json(asdict(identity))
        else:
            table = Table(title="Identity")
            table.add_column("Field")
            table.add_column("Value")
            table.add_row("displayName", identity.display_name)
            table.add_row("objectId", identity.id)
            table.add_row("appId", identity.app_id)
            table.add_row("blueprintId", identity.blueprint_id or "")
            table.add_row("accountEnabled", str(identity.account_enabled))
            console.print(table)

        if permissions:
            _show_permissions_for_sp(client, identity.id)
    finally:
        client.close()


@create_app.command("graph")
def create_graph(
    blueprint_name: Annotated[str, typer.Option("--blueprint-name")],
    identity_name: Annotated[str, typer.Option("--identity-name")],
    sponsor_object_id: Annotated[str | None, typer.Option("--sponsor-object-id")] = None,
    registration_name: Annotated[str | None, typer.Option("--registration-name")] = None,
    description: Annotated[str | None, typer.Option("--description")] = None,
    tenant_id: Annotated[str | None, typer.Option("--tenant-id")] = None,
    register: Annotated[bool, typer.Option("--register/--no-register")] = True,
    output_json: Annotated[bool, typer.Option("--json")] = False,
) -> None:
    """
    Create blueprint + principal + identity, and optionally register in admin portal.
    """
    client = _client(tenant_id)
    try:
        owner_id = client.current_user_id()
        sponsor_id = sponsor_object_id or owner_id

        blueprint = client.create_blueprint(blueprint_name, sponsor_id)
        client.create_blueprint_principal(blueprint.app_id)
        identity = client.create_identity(identity_name, blueprint.id, sponsor_id)

        registration: AgentRegistration | None = None
        if register:
            registration = client.register_agent(
                display_name=registration_name or f"{identity_name} Agent",
                blueprint_id=blueprint.id,
                agent_identity_id=identity.id,
                owner_id=owner_id,
                description=description,
            )

        payload = {
            "blueprint": asdict(blueprint),
            "identity": asdict(identity),
            "registration": asdict(registration) if registration else None,
        }
        if output_json:
            _as_json(payload)
            return
        console.print("[green]Created blueprint and identity.[/green]")
        console.print_json(data=json.dumps(payload, indent=2))
    finally:
        client.close()


@create_app.command("a365")
def create_via_a365(
    agent_name: Annotated[str, typer.Option("--agent-name")],
    tenant_id: Annotated[str | None, typer.Option("--tenant-id")] = None,
    m365: Annotated[bool, typer.Option("--m365/--non-m365")] = False,
    dry_run: Annotated[bool, typer.Option("--dry-run")] = False,
) -> None:
    """Delegate creation to a365 setup all."""
    cmd, output = create_with_a365(
        agent_name=agent_name,
        tenant_id=tenant_id,
        include_m365=m365,
        dry_run=dry_run,
    )
    console.print(f"[cyan]Executed:[/cyan] {cmd}")
    console.print(output)


@delete_app.command("identity")
def delete_identity(
    selector: str,
    tenant_id: Annotated[str | None, typer.Option("--tenant-id")] = None,
    force: Annotated[bool, typer.Option("--force")] = False,
) -> None:
    """Delete one agent identity."""
    client = _client(tenant_id)
    try:
        identity = client.resolve_identity(selector)
        if not force:
            _confirm(identity.display_name)
        client.delete_identity(identity.id)
        console.print(f"[green]Deleted identity:[/green] {identity.display_name} ({identity.id})")
    finally:
        client.close()


@delete_app.command("blueprint")
def delete_blueprint(
    selector: str,
    tenant_id: Annotated[str | None, typer.Option("--tenant-id")] = None,
    force: Annotated[bool, typer.Option("--force")] = False,
) -> None:
    """Delete one blueprint and let server-side cascade clean children."""
    client = _client(tenant_id)
    try:
        blueprint = client.resolve_blueprint(selector)
        identities = [i for i in client.list_identities() if i.blueprint_id == blueprint.id]
        if identities:
            console.print("[yellow]This blueprint has child identities:[/yellow]")
            for identity in identities:
                console.print(f" - {identity.display_name} ({identity.id})")
        if not force:
            _confirm(blueprint.display_name)
        client.delete_blueprint(blueprint.id)
        console.print(f"[green]Deleted blueprint:[/green] {blueprint.display_name} ({blueprint.id})")
    finally:
        client.close()


@delete_app.command("registration")
def delete_registration(
    selector: str,
    tenant_id: Annotated[str | None, typer.Option("--tenant-id")] = None,
    force: Annotated[bool, typer.Option("--force")] = False,
) -> None:
    """Delete one Agent 365 registry entry."""
    client = _client(tenant_id)
    try:
        registration = _match_registration(client.list_registrations(), selector)
        if not force:
            _confirm(registration.display_name)
        client.delete_registration(registration.id)
        console.print(
            f"[green]Deleted registration:[/green] {registration.display_name} ({registration.id})"
        )
    finally:
        client.close()


def _run() -> int:
    try:
        app()
        return 0
    except (GraphError, AuthError, A365Error, ValueError) as exc:
        console.print(f"[red]Error:[/red] {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(_run())

