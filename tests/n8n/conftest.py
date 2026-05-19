from pathlib import Path
import pytest

FIXTURES_DIR = Path(__file__).parent / "fixtures"

@pytest.fixture
def matrix_yaml(tmp_path):
    """Minimal credentials matrix for tests."""
    matrix = tmp_path / "credentials-matrix.yaml"
    matrix.write_text(
        "workflows:\n"
        "  discover:\n"
        "    file: discover.json\n"
        "    allow:\n"
        "      - outreach-db-n8n\n"
        "      - discover-webhook-secret\n"
        "forbidden_phase1:\n"
        "  - postiz-api-key\n"
    )
    return matrix

@pytest.fixture
def compliant_workflow(tmp_path):
    src = FIXTURES_DIR / "workflow_compliant.json"
    dst = tmp_path / "discover.json"
    dst.write_text(src.read_text())
    return dst

@pytest.fixture
def violating_workflow(tmp_path):
    src = FIXTURES_DIR / "workflow_violation.json"
    dst = tmp_path / "discover.json"
    dst.write_text(src.read_text())
    return dst
