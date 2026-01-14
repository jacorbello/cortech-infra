#!/usr/bin/env python3
"""
DocSync: Continuous document ingestion from MinIO to Dify Knowledge.

Watches the jarvis-docrepo bucket in MinIO and syncs documents to
corresponding Dify Knowledge datasets based on prefix routing.
"""

import os
import sys
import json
import hashlib
import logging
import time
from pathlib import Path
from datetime import datetime, timezone
from typing import Optional

import boto3
from botocore.config import Config
import requests

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("docsync")

# Configuration from environment
MINIO_ENDPOINT = os.environ.get("MINIO_ENDPOINT", "http://192.168.1.118:9000")
MINIO_ACCESS_KEY = os.environ.get("MINIO_ACCESS_KEY", "LGAM2QDJY0K1EZVDJ6XZ")
MINIO_SECRET_KEY = os.environ.get("MINIO_SECRET_KEY", "")
MINIO_BUCKET = os.environ.get("MINIO_BUCKET", "jarvis-docrepo")

DIFY_API_BASE = os.environ.get("DIFY_API_BASE", "https://dify.corbello.io/v1")
DIFY_API_KEY = os.environ.get("DIFY_API_KEY", "")

# Manifest file location in MinIO
MANIFEST_KEY = ".docsync-manifest.json"

# Prefix to Dataset ID mapping
DATASET_ROUTING = {
    "infra/": os.environ.get("DATASET_INFRA", "c65ddc66-dd27-4b8a-a10b-aae6f29dc249"),
    "jarvis/": os.environ.get("DATASET_JARVIS", "b3312ebe-06c0-42a6-bb77-a079c6787729"),
    "legal/": os.environ.get("DATASET_LEGAL", "8d0add86-f413-4b2e-8daf-e7654bed3859"),
    "a2g/": os.environ.get("DATASET_A2G", "345a54bd-fead-4074-831a-badb15f3a2cc"),
}

# Supported file extensions
SUPPORTED_EXTENSIONS = {".md", ".txt", ".pdf", ".docx", ".html", ".json", ".yaml", ".yml"}


class DocSync:
    def __init__(self):
        self.s3 = boto3.client(
            "s3",
            endpoint_url=MINIO_ENDPOINT,
            aws_access_key_id=MINIO_ACCESS_KEY,
            aws_secret_access_key=MINIO_SECRET_KEY,
            config=Config(signature_version="s3v4"),
            region_name="us-east-1",
        )
        self.manifest = {}

    def load_manifest(self) -> dict:
        """Load the sync manifest from MinIO."""
        try:
            response = self.s3.get_object(Bucket=MINIO_BUCKET, Key=MANIFEST_KEY)
            self.manifest = json.loads(response["Body"].read().decode("utf-8"))
            log.info(f"Loaded manifest with {len(self.manifest)} entries")
        except self.s3.exceptions.NoSuchKey:
            log.info("No existing manifest found, starting fresh")
            self.manifest = {}
        except Exception as e:
            log.warning(f"Failed to load manifest: {e}")
            self.manifest = {}
        return self.manifest

    def save_manifest(self):
        """Save the sync manifest to MinIO."""
        try:
            self.s3.put_object(
                Bucket=MINIO_BUCKET,
                Key=MANIFEST_KEY,
                Body=json.dumps(self.manifest, indent=2).encode("utf-8"),
                ContentType="application/json",
            )
            log.info(f"Saved manifest with {len(self.manifest)} entries")
        except Exception as e:
            log.error(f"Failed to save manifest: {e}")

    def list_objects(self) -> list:
        """List all objects in the bucket."""
        objects = []
        paginator = self.s3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=MINIO_BUCKET):
            for obj in page.get("Contents", []):
                key = obj["Key"]
                # Skip manifest and hidden files
                if key == MANIFEST_KEY or key.endswith("/.keep"):
                    continue
                # Check extension
                ext = Path(key).suffix.lower()
                if ext in SUPPORTED_EXTENSIONS:
                    objects.append({
                        "key": key,
                        "etag": obj["ETag"].strip('"'),
                        "size": obj["Size"],
                        "last_modified": obj["LastModified"].isoformat(),
                    })
        return objects

    def get_dataset_id(self, key: str) -> Optional[str]:
        """Route a key to a dataset ID based on prefix."""
        for prefix, dataset_id in DATASET_ROUTING.items():
            if key.startswith(prefix):
                return dataset_id
        log.warning(f"No dataset routing for key: {key}")
        return None

    def download_object(self, key: str) -> Optional[bytes]:
        """Download an object from MinIO."""
        try:
            response = self.s3.get_object(Bucket=MINIO_BUCKET, Key=key)
            return response["Body"].read()
        except Exception as e:
            log.error(f"Failed to download {key}: {e}")
            return None

    def get_dify_headers(self):
        """Get headers for Dify API requests."""
        return {
            "Authorization": f"Bearer {DIFY_API_KEY}",
            "Content-Type": "application/json",
        }

    def list_dify_documents(self, dataset_id: str) -> dict:
        """List existing documents in a Dify dataset."""
        url = f"{DIFY_API_BASE}/datasets/{dataset_id}/documents"
        try:
            resp = requests.get(url, headers=self.get_dify_headers(), params={"limit": 100})
            resp.raise_for_status()
            return {doc["name"]: doc for doc in resp.json().get("data", [])}
        except Exception as e:
            log.error(f"Failed to list documents in dataset {dataset_id}: {e}")
            return {}

    def create_dify_document(self, dataset_id: str, name: str, text: str) -> bool:
        """Create a new document in Dify."""
        url = f"{DIFY_API_BASE}/datasets/{dataset_id}/document/create-by-text"
        payload = {
            "name": name,
            "text": text,
            "indexing_technique": "high_quality",
            "process_rule": {"mode": "automatic"},
        }
        try:
            resp = requests.post(url, headers=self.get_dify_headers(), json=payload)
            resp.raise_for_status()
            return True
        except Exception as e:
            log.error(f"Failed to create document {name}: {e}")
            return False

    def update_dify_document(self, dataset_id: str, doc_id: str, name: str, text: str) -> bool:
        """Update an existing document in Dify."""
        url = f"{DIFY_API_BASE}/datasets/{dataset_id}/documents/{doc_id}/update-by-text"
        payload = {
            "name": name,
            "text": text,
            "process_rule": {"mode": "automatic"},
        }
        try:
            resp = requests.post(url, headers=self.get_dify_headers(), json=payload)
            resp.raise_for_status()
            return True
        except Exception as e:
            log.error(f"Failed to update document {name}: {e}")
            return False

    def sync_object(self, obj: dict) -> bool:
        """Sync a single object to Dify."""
        key = obj["key"]
        etag = obj["etag"]

        # Check if already synced with same etag
        if key in self.manifest and self.manifest[key].get("etag") == etag:
            log.debug(f"Skipping {key} (unchanged)")
            return True

        # Get dataset ID
        dataset_id = self.get_dataset_id(key)
        if not dataset_id:
            return False

        # Download content
        content = self.download_object(key)
        if content is None:
            return False

        # Decode text (skip binary files for now)
        try:
            text = content.decode("utf-8")
        except UnicodeDecodeError:
            log.warning(f"Skipping binary file: {key}")
            return False

        # Get existing documents in dataset
        existing_docs = self.list_dify_documents(dataset_id)
        doc_name = key  # Use full path as document name

        if doc_name in existing_docs:
            # Update existing
            log.info(f"Updating: {key}")
            success = self.update_dify_document(
                dataset_id, existing_docs[doc_name]["id"], doc_name, text
            )
        else:
            # Create new
            log.info(f"Creating: {key}")
            success = self.create_dify_document(dataset_id, doc_name, text)

        if success:
            self.manifest[key] = {
                "etag": etag,
                "synced_at": datetime.now(timezone.utc).isoformat(),
                "dataset_id": dataset_id,
            }

        return success

    def run_once(self) -> tuple[int, int, int]:
        """Run a single sync cycle. Returns (synced, skipped, failed) counts."""
        log.info("Starting sync cycle...")
        self.load_manifest()

        objects = self.list_objects()
        log.info(f"Found {len(objects)} objects to process")

        synced = 0
        skipped = 0
        failed = 0

        for obj in objects:
            key = obj["key"]
            etag = obj["etag"]

            # Check if unchanged
            if key in self.manifest and self.manifest[key].get("etag") == etag:
                skipped += 1
                continue

            if self.sync_object(obj):
                synced += 1
            else:
                failed += 1

        self.save_manifest()
        log.info(f"Sync complete: {synced} synced, {skipped} skipped, {failed} failed")
        return synced, skipped, failed

    def run_daemon(self, interval: int = 300):
        """Run as a daemon, syncing every interval seconds."""
        log.info(f"Starting daemon mode (interval: {interval}s)")
        while True:
            try:
                self.run_once()
            except Exception as e:
                log.error(f"Sync cycle failed: {e}")
            log.info(f"Sleeping for {interval} seconds...")
            time.sleep(interval)


def main():
    import argparse

    parser = argparse.ArgumentParser(description="DocSync: MinIO to Dify Knowledge sync")
    parser.add_argument("--daemon", "-d", action="store_true", help="Run as daemon")
    parser.add_argument("--interval", "-i", type=int, default=300, help="Sync interval in seconds (daemon mode)")
    parser.add_argument("--dry-run", "-n", action="store_true", help="Show what would be done")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # Validate required env vars
    if not MINIO_SECRET_KEY:
        log.error("MINIO_SECRET_KEY environment variable is required")
        sys.exit(1)
    if not DIFY_API_KEY:
        log.error("DIFY_API_KEY environment variable is required")
        sys.exit(1)

    sync = DocSync()

    if args.dry_run:
        log.info("Dry run mode - listing objects only")
        sync.load_manifest()
        objects = sync.list_objects()
        for obj in objects:
            key = obj["key"]
            etag = obj["etag"]
            status = "SKIP" if key in sync.manifest and sync.manifest[key].get("etag") == etag else "SYNC"
            dataset = sync.get_dataset_id(key) or "NO_DATASET"
            print(f"[{status}] {key} -> {dataset}")
    elif args.daemon:
        sync.run_daemon(args.interval)
    else:
        sync.run_once()


if __name__ == "__main__":
    main()
