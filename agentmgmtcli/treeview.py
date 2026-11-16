from __future__ import annotations

from collections import defaultdict
from typing import Iterable

from rich.tree import Tree

from .models import AgentIdentity, AgentRegistration, Blueprint


def build_tree(
    blueprints: Iterable[Blueprint],
    identities: Iterable[AgentIdentity],
    registrations: Iterable[AgentRegistration],
) -> Tree:
    root = Tree("Agent ID")
    ids_by_bp: dict[str, list[AgentIdentity]] = defaultdict(list)
    for identity in identities:
        if identity.blueprint_id:
            ids_by_bp[identity.blueprint_id].append(identity)

    reg_by_bp: dict[str, list[AgentRegistration]] = defaultdict(list)
    for registration in registrations:
        if registration.blueprint_id:
            reg_by_bp[registration.blueprint_id].append(registration)

    unlinked_ids: list[AgentIdentity] = []
    for identity in identities:
        if not identity.blueprint_id:
            unlinked_ids.append(identity)

    for blueprint in sorted(blueprints, key=lambda b: b.display_name.lower()):
        bp_node = root.add(f"[bold]{blueprint.display_name}[/bold] ({blueprint.app_id})")
        bp_node.add(f"objectId: {blueprint.id}")
        regs = reg_by_bp.get(blueprint.id, [])
        if regs:
            reg_group = bp_node.add("registrations")
            for reg in regs:
                reg_group.add(f"{reg.display_name} ({reg.id})")
        children = ids_by_bp.get(blueprint.id, [])
        if children:
            id_group = bp_node.add("identities")
            for child in sorted(children, key=lambda i: i.display_name.lower()):
                state = "enabled" if child.account_enabled else "disabled"
                id_group.add(f"{child.display_name} ({child.app_id}) [{state}]")
        else:
            bp_node.add("[dim]no linked identities found[/dim]")

    if unlinked_ids:
        other = root.add("[yellow]unlinked identities[/yellow]")
        for identity in sorted(unlinked_ids, key=lambda i: i.display_name.lower()):
            other.add(f"{identity.display_name} ({identity.id})")

    return root

