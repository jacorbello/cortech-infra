#!/usr/bin/env python3
"""
Dify Knowledge Base Ingestion Script
Syncs markdown files from the infrastructure repo to Dify datasets.
"""

import os
import sys
import json
import hashlib
import requests
from pathlib import Path

# Configuration
DIFY_API_BASE = "https://dify.corbello.io/v1"
DIFY_API_KEY = os.environ.get("DIFY_API_KEY", "dataset-AKsRFEGG7cmCgaoSL85JxkCb")

# Dataset IDs
DATASETS = {
    "infra-docs": "c65ddc66-dd27-4b8a-a10b-aae6f29dc249",
    "jarvis-docs": "b3312ebe-06c0-42a6-bb77-a079c6787729",
    "legal": "8d0add86-f413-4b2e-8daf-e7654bed3859",
    "a2g": "345a54bd-fead-4074-831a-badb15f3a2cc",
}

# File to dataset mapping (glob patterns)
FILE_MAPPINGS = {
    "infra-docs": [
        "README.md",
        "CLAUDE.md",
        "AGENTS.md",
        "docs/**/*.md",
        "plans/dify-cutover.md",
        "plans/jarvis-observability.md",
    ],
    "jarvis-docs": [
        "jarvis/**/*.md",
        "plans/jarvis/**/*.md",
        "plans/jarvis-*.md",
    ],
}

REPO_ROOT = Path("/root/repos/infrastructure")


def get_headers():
    return {
        "Authorization": f"Bearer {DIFY_API_KEY}",
        "Content-Type": "application/json",
    }


def list_documents(dataset_id):
    """List existing documents in a dataset."""
    url = f"{DIFY_API_BASE}/datasets/{dataset_id}/documents"
    resp = requests.get(url, headers=get_headers(), params={"limit": 100})
    resp.raise_for_status()
    return {doc["name"]: doc for doc in resp.json().get("data", [])}


def create_document(dataset_id, name, text):
    """Create a new document in a dataset."""
    url = f"{DIFY_API_BASE}/datasets/{dataset_id}/document/create-by-text"
    payload = {
        "name": name,
        "text": text,
        "indexing_technique": "high_quality",
        "process_rule": {"mode": "automatic"},
    }
    resp = requests.post(url, headers=get_headers(), json=payload)
    resp.raise_for_status()
    return resp.json()


def update_document(dataset_id, document_id, name, text):
    """Update an existing document."""
    url = f"{DIFY_API_BASE}/datasets/{dataset_id}/documents/{document_id}/update-by-text"
    payload = {
        "name": name,
        "text": text,
        "process_rule": {"mode": "automatic"},
    }
    resp = requests.post(url, headers=get_headers(), json=payload)
    resp.raise_for_status()
    return resp.json()


def find_files(patterns):
    """Find files matching glob patterns."""
    files = set()
    for pattern in patterns:
        for path in REPO_ROOT.glob(pattern):
            if path.is_file():
                files.add(path)
    return sorted(files)


def get_doc_name(file_path):
    """Generate document name from file path."""
    rel_path = file_path.relative_to(REPO_ROOT)
    return str(rel_path)


def ingest_dataset(dataset_name, dry_run=False):
    """Ingest files into a dataset."""
    if dataset_name not in DATASETS:
        print(f"Unknown dataset: {dataset_name}")
        return

    dataset_id = DATASETS[dataset_name]
    patterns = FILE_MAPPINGS.get(dataset_name, [])

    if not patterns:
        print(f"No file mappings for dataset: {dataset_name}")
        return

    print(f"\n{'='*60}")
    print(f"Ingesting into: {dataset_name} ({dataset_id})")
    print(f"{'='*60}")

    # Get existing documents
    existing = list_documents(dataset_id)
    print(f"Existing documents: {len(existing)}")

    # Find files to ingest
    files = find_files(patterns)
    print(f"Files to process: {len(files)}")

    for file_path in files:
        doc_name = get_doc_name(file_path)

        try:
            content = file_path.read_text(encoding="utf-8")
        except Exception as e:
            print(f"  SKIP {doc_name}: {e}")
            continue

        if doc_name in existing:
            if dry_run:
                print(f"  UPDATE {doc_name}")
            else:
                print(f"  UPDATE {doc_name}...", end=" ")
                try:
                    update_document(dataset_id, existing[doc_name]["id"], doc_name, content)
                    print("OK")
                except Exception as e:
                    print(f"FAILED: {e}")
        else:
            if dry_run:
                print(f"  CREATE {doc_name}")
            else:
                print(f"  CREATE {doc_name}...", end=" ")
                try:
                    create_document(dataset_id, doc_name, content)
                    print("OK")
                except Exception as e:
                    print(f"FAILED: {e}")


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Ingest docs into Dify Knowledge")
    parser.add_argument("--dataset", "-d", help="Specific dataset to ingest")
    parser.add_argument("--dry-run", "-n", action="store_true", help="Show what would be done")
    parser.add_argument("--list", "-l", action="store_true", help="List datasets and exit")
    args = parser.parse_args()

    if args.list:
        print("Available datasets:")
        for name, dataset_id in DATASETS.items():
            patterns = FILE_MAPPINGS.get(name, [])
            files = find_files(patterns) if patterns else []
            print(f"  {name}: {len(files)} files -> {dataset_id}")
        return

    datasets_to_process = [args.dataset] if args.dataset else ["infra-docs", "jarvis-docs"]

    for dataset in datasets_to_process:
        ingest_dataset(dataset, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
