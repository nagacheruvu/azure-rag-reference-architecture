"""Upload a local folder of documents to the Ask Maya 'documents' blob container.

Handles a large, mixed corpus (10-50 GB of PDF/DOCX/PPTX/XLSX/TXT/HTML/JSON): the Azure Blob
SDK automatically splits big files into block uploads, and `max_concurrency` parallelises each.
The folder tree is preserved as blob name prefixes so the Search indexer can crack everything.

Auth is keyless (managed identity / `az login`) — no account keys or SAS.

  NOTE (MCAPS tenants): the storage account's public network access may be auto-disabled by
  policy minutes after creation, causing data-plane 403 AuthorizationFailure. If uploads fail
  with 403, re-enable it first:
      az storage account update -g <rg> -n <account> --public-network-access Enabled

Run AFTER `azd up`. Config is read from the azd environment (.azure/<env>/.env) or env vars:
  AZURE_STORAGE_BLOB_ENDPOINT (or AZURE_STORAGE_ACCOUNT), AZURE_STORAGE_CONTAINER

Usage:
  pip install -r scripts/requirements.txt
  python scripts/upload_docs.py --path ./my-docs
  python scripts/upload_docs.py --path ./my-docs --run-indexer   # trigger reindex after upload
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

UPLOAD_MAX_CONCURRENCY = 8  # parallel block uploads per file


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _blob_endpoint() -> str:
    endpoint = _env("AZURE_STORAGE_BLOB_ENDPOINT")
    if endpoint:
        return endpoint
    account = _env("AZURE_STORAGE_ACCOUNT")
    if account:
        return f"https://{account}.blob.core.windows.net"
    sys.exit(
        "Missing storage endpoint. Set AZURE_STORAGE_BLOB_ENDPOINT or AZURE_STORAGE_ACCOUNT "
        "(populated by `azd up`)."
    )


def iter_files(root: Path):
    for path in root.rglob("*"):
        if path.is_file():
            yield path


def main() -> None:
    parser = argparse.ArgumentParser(description="Upload documents to the Ask Maya blob container.")
    parser.add_argument("--path", required=True, help="Local folder of documents to upload.")
    parser.add_argument("--container", default=_env("AZURE_STORAGE_CONTAINER", "documents"),
                        help="Target blob container (default: documents).")
    parser.add_argument("--run-indexer", action="store_true",
                        help="Trigger the AI Search indexer after upload (delegates to setup_search.py).")
    args = parser.parse_args()

    root = Path(args.path).expanduser().resolve()
    if not root.is_dir():
        sys.exit(f"Not a directory: {root}")

    service = BlobServiceClient(account_url=_blob_endpoint(), credential=DefaultAzureCredential())
    container = service.get_container_client(args.container)
    try:
        container.create_container()
    except Exception:
        pass  # already exists

    files = list(iter_files(root))
    if not files:
        sys.exit(f"No files found under {root}")

    total = len(files)
    total_bytes = sum(f.stat().st_size for f in files)
    print(f"Uploading {total} files ({total_bytes / 1e9:.2f} GB) to '{args.container}'...")

    for i, path in enumerate(files, start=1):
        blob_name = path.relative_to(root).as_posix()
        with path.open("rb") as data:
            container.upload_blob(
                name=blob_name,
                data=data,
                overwrite=True,
                max_concurrency=UPLOAD_MAX_CONCURRENCY,
            )
        print(f"  [{i}/{total}] {blob_name}")

    print("Upload complete.")

    if args.run_indexer:
        print("Triggering indexer...")
        import subprocess

        script = Path(__file__).with_name("setup_search.py")
        subprocess.run([sys.executable, str(script), "--run"], check=True)


if __name__ == "__main__":
    main()
