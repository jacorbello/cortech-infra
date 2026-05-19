import pytest
from scripts.n8n.audit_credentials import audit_workflow_dir, AuditViolation

def test_compliant_workflow_passes(tmp_path, matrix_yaml, compliant_workflow):
    # compliant_workflow lives in tmp_path; matrix_yaml lives in tmp_path
    violations = audit_workflow_dir(workflow_dir=tmp_path, matrix_path=matrix_yaml)
    assert violations == []

def test_violating_workflow_fails(tmp_path, matrix_yaml, violating_workflow):
    violations = audit_workflow_dir(workflow_dir=tmp_path, matrix_path=matrix_yaml)
    assert len(violations) == 1
    v = violations[0]
    assert v.workflow == "discover"
    assert v.disallowed_credential == "anthropic-api-key"

def test_unknown_workflow_file_is_violation(tmp_path, matrix_yaml):
    # A workflow JSON file with no matching entry in the matrix is fail-closed.
    rogue = tmp_path / "rogue.json"
    rogue.write_text('{"name": "rogue", "nodes": []}')
    violations = audit_workflow_dir(workflow_dir=tmp_path, matrix_path=matrix_yaml)
    assert any(v.reason == "workflow_not_in_matrix" for v in violations)

def test_missing_workflow_file_is_violation(tmp_path, matrix_yaml):
    # The matrix lists discover.json but the file is missing.
    violations = audit_workflow_dir(workflow_dir=tmp_path, matrix_path=matrix_yaml)
    assert any(v.reason == "workflow_file_missing" for v in violations)
