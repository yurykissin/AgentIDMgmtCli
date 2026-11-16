from __future__ import annotations

import shlex
import subprocess


class A365Error(RuntimeError):
    pass


def create_with_a365(
    *,
    agent_name: str,
    tenant_id: str | None = None,
    include_m365: bool = False,
    dry_run: bool = False,
) -> tuple[str, str]:
    args = ["a365", "setup", "all", "--agent-name", agent_name]
    if tenant_id:
        args.extend(["--tenant-id", tenant_id])
    if include_m365:
        args.append("--m365")
    if dry_run:
        args.append("--dry-run")

    rendered = " ".join(shlex.quote(a) for a in args)
    proc = subprocess.run(args, check=False, capture_output=True, text=True)
    if proc.returncode != 0:
        raise A365Error(f"{rendered}\n\n{proc.stdout}\n{proc.stderr}")
    return rendered, proc.stdout

