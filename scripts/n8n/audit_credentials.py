"""Audit n8n workflow JSON exports against a declarative credentials allowlist.

Usage:
    python -m scripts.n8n.audit_credentials apps/outreach-workflows/

Exit code 0: no violations. Exit code 1: violations printed to stderr.
"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path

import yaml


@dataclass
class AuditViolation:
    workflow: str
    reason: str
    disallowed_credential: str | None = None
    file_path: str | None = None

    def format(self) -> str:
        if self.reason == "disallowed_credential":
            return (
                f"{self.workflow}: references credential "
                f"'{self.disallowed_credential}' which is not in its allowlist"
            )
        if self.reason == "forbidden_phase1_credential":
            return (
                f"{self.workflow}: references forbidden Phase 1 credential "
                f"'{self.disallowed_credential}'"
            )
        if self.reason == "workflow_not_in_matrix":
            return (
                f"{self.workflow}: file present but no entry in credentials-matrix.yaml "
                f"(fail-closed)"
            )
        if self.reason == "workflow_file_missing":
            return f"{self.workflow}: matrix entry exists but file missing at {self.file_path}"
        return f"{self.workflow}: {self.reason}"


def _extract_credentials(workflow_json: dict) -> list[str]:
    """Return the list of credential names referenced anywhere in the workflow."""
    names: list[str] = []
    for node in workflow_json.get("nodes", []):
        creds = node.get("credentials") or {}
        for cred_def in creds.values():
            name = cred_def.get("name")
            if name:
                names.append(name)
    return names


def audit_workflow_dir(workflow_dir: Path, matrix_path: Path) -> list[AuditViolation]:
    """Audit every workflow JSON in `workflow_dir` against `matrix_path`."""
    matrix = yaml.safe_load(matrix_path.read_text())
    workflows_spec = matrix.get("workflows", {})
    forbidden_phase1 = set(matrix.get("forbidden_phase1", []))

    violations: list[AuditViolation] = []

    # Build a map of expected filenames to their spec
    expected_files = {
        Path(spec["file"]).name: (name, spec)
        for name, spec in workflows_spec.items()
    }

    # Check each JSON file in the workflow_dir
    found_files: set[str] = set()
    for json_file in workflow_dir.glob("*.json"):
        found_files.add(json_file.name)
        if json_file.name not in expected_files:
            violations.append(
                AuditViolation(
                    workflow=json_file.stem,
                    reason="workflow_not_in_matrix",
                    file_path=str(json_file),
                )
            )
            continue

        workflow_name, spec = expected_files[json_file.name]
        allowed = set(spec.get("allow", []))
        wf_raw = json.loads(json_file.read_text())
        # n8n export:workflow wraps in an array; unwrap if needed.
        wf_json = wf_raw[0] if isinstance(wf_raw, list) else wf_raw
        for cred_name in _extract_credentials(wf_json):
            if cred_name in forbidden_phase1:
                violations.append(
                    AuditViolation(
                        workflow=workflow_name,
                        reason="forbidden_phase1_credential",
                        disallowed_credential=cred_name,
                    )
                )
            elif cred_name not in allowed:
                violations.append(
                    AuditViolation(
                        workflow=workflow_name,
                        reason="disallowed_credential",
                        disallowed_credential=cred_name,
                    )
                )

    # Check for missing files
    for expected_name, (workflow_name, spec) in expected_files.items():
        if expected_name not in found_files:
            violations.append(
                AuditViolation(
                    workflow=workflow_name,
                    reason="workflow_file_missing",
                    file_path=spec["file"],
                )
            )

    return violations


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("Usage: audit_credentials.py <workflow-dir>", file=sys.stderr)
        return 2
    workflow_dir = Path(argv[1])
    matrix_path = workflow_dir / "credentials-matrix.yaml"
    if not matrix_path.exists():
        # If we were passed the parent, look one level in
        alt = workflow_dir / "outreach-workflows" / "credentials-matrix.yaml"
        if alt.exists():
            matrix_path = alt
            workflow_dir = workflow_dir / "outreach-workflows" / "n8n"
        else:
            print(f"ERROR: credentials-matrix.yaml not found near {workflow_dir}", file=sys.stderr)
            return 2
    else:
        workflow_dir = workflow_dir / "n8n"

    violations = audit_workflow_dir(workflow_dir=workflow_dir, matrix_path=matrix_path)
    if violations:
        print(f"{len(violations)} violation(s):", file=sys.stderr)
        for v in violations:
            print(f"  - {v.format()}", file=sys.stderr)
        return 1
    print("Audit passed: no credential violations.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
