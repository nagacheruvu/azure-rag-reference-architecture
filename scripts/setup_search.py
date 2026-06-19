"""Provision the Ask Maya document-ingestion pipeline in Azure AI Search.

Creates four data-plane objects via the stable Search REST API (api-version 2024-07-01) so
the script is independent of SDK class churn:

  1. Index       — chunk-level schema with an HNSW vector field + semantic config.
  2. Data source — keyless (managed-identity) connection to the Blob 'documents' container.
  3. Skillset    — SplitSkill (pages) -> AzureOpenAIEmbeddingSkill (integrated vectorization),
                   projected one-chunk-per-document via index projections.
  4. Indexer     — binds source + skillset + index; runs on a schedule to pick up new blobs.

Azure AI Search natively cracks PDF, DOCX, PPTX, XLSX, HTML, TXT, JSON and more, so mixed
document formats are handled with no extra parser. For scanned/complex-table PDFs, add an
Azure AI Document Intelligence skill later.

Auth is keyless end-to-end:
  - This script calls the Search control plane with your Entra token (scope search.azure.com).
  - The Search service's own managed identity reads blobs and calls Azure OpenAI for embeddings
    (role assignments are provisioned in infra/resources.bicep).

Run AFTER `azd up`. Config is read from the azd environment (.azure/<env>/.env) or env vars:

  AZURE_SEARCH_ENDPOINT, AZURE_SEARCH_INDEX, AZURE_OPENAI_ENDPOINT,
  AZURE_OPENAI_EMBEDDING_DEPLOYMENT, AZURE_STORAGE_RESOURCE_ID, AZURE_STORAGE_CONTAINER

Usage:
  pip install -r scripts/requirements.txt
  python scripts/setup_search.py            # create/update everything
  python scripts/setup_search.py --run      # ...and kick off an indexer run
"""

from __future__ import annotations

import argparse
import os
import sys

import requests
from azure.identity import DefaultAzureCredential

API_VERSION = "2024-07-01"
SEARCH_SCOPE = "https://search.azure.com/.default"
EMBEDDING_DIMENSIONS = 1536  # text-embedding-3-small


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _require(values: dict[str, str]) -> None:
    missing = [k for k, v in values.items() if not v]
    if missing:
        sys.exit(
            "Missing required configuration: "
            + ", ".join(missing)
            + "\nRun `azd up` first, or set these environment variables."
        )


class SearchAdmin:
    def __init__(self, endpoint: str) -> None:
        self._endpoint = endpoint.rstrip("/")
        self._credential = DefaultAzureCredential()

    def _headers(self) -> dict[str, str]:
        token = self._credential.get_token(SEARCH_SCOPE).token
        return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

    def put(self, resource: str, name: str, body: dict) -> None:
        url = f"{self._endpoint}/{resource}/{name}?api-version={API_VERSION}"
        resp = requests.put(url, json=body, headers=self._headers(), timeout=60)
        if resp.status_code not in (200, 201):
            sys.exit(f"PUT {resource}/{name} failed ({resp.status_code}): {resp.text}")
        print(f"  ✓ {resource}/{name}")

    def run_indexer(self, name: str) -> None:
        url = f"{self._endpoint}/indexers/{name}/run?api-version={API_VERSION}"
        resp = requests.post(url, headers=self._headers(), timeout=60)
        if resp.status_code not in (202, 200):
            sys.exit(f"Run indexer failed ({resp.status_code}): {resp.text}")
        print(f"  ▶ indexer '{name}' run started — track status in the portal.")


def build_index(name: str, aoai_endpoint: str, embedding_deployment: str) -> dict:
    return {
        "name": name,
        "fields": [
            {"name": "chunk_id", "type": "Edm.String", "key": True, "filterable": True,
             "sortable": True, "analyzer": "keyword"},
            {"name": "parent_id", "type": "Edm.String", "filterable": True},
            {"name": "title", "type": "Edm.String", "searchable": True, "filterable": True},
            {"name": "chunk", "type": "Edm.String", "searchable": True},
            {"name": "text_vector", "type": "Collection(Edm.Single)", "searchable": True,
             "retrievable": False, "dimensions": EMBEDDING_DIMENSIONS,
             "vectorSearchProfile": "vprofile"},
        ],
        "vectorSearch": {
            "algorithms": [{"name": "hnsw", "kind": "hnsw"}],
            "profiles": [{"name": "vprofile", "algorithm": "hnsw", "vectorizer": "aoai"}],
            "vectorizers": [{
                "name": "aoai",
                "kind": "azureOpenAI",
                "azureOpenAIParameters": {
                    "resourceUri": aoai_endpoint,
                    "deploymentId": embedding_deployment,
                    "modelName": "text-embedding-3-small",
                },
            }],
        },
        "semantic": {
            "configurations": [{
                "name": "semantic-config",
                "prioritizedFields": {
                    "titleField": {"fieldName": "title"},
                    "prioritizedContentFields": [{"fieldName": "chunk"}],
                },
            }],
        },
    }


def build_data_source(name: str, storage_resource_id: str, container: str) -> dict:
    # ResourceId form => Search uses its own managed identity (no keys/SAS).
    return {
        "name": name,
        "type": "azureblob",
        "credentials": {"connectionString": f"ResourceId={storage_resource_id};"},
        "container": {"name": container},
    }


def build_skillset(name: str, index_name: str, aoai_endpoint: str, embedding_deployment: str) -> dict:
    return {
        "name": name,
        "skills": [
            {
                "@odata.type": "#Microsoft.Skills.Text.SplitSkill",
                "name": "split",
                "textSplitMode": "pages",
                "maximumPageLength": 2000,
                "pageOverlapLength": 500,
                "context": "/document",
                "inputs": [{"name": "text", "source": "/document/content"}],
                "outputs": [{"name": "textItems", "targetName": "pages"}],
            },
            {
                "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
                "name": "embed",
                "context": "/document/pages/*",
                "resourceUri": aoai_endpoint,
                "deploymentId": embedding_deployment,
                "modelName": "text-embedding-3-small",
                "dimensions": EMBEDDING_DIMENSIONS,
                "inputs": [{"name": "text", "source": "/document/pages/*"}],
                "outputs": [{"name": "embedding", "targetName": "text_vector"}],
            },
        ],
        "indexProjections": {
            "selectors": [{
                "targetIndexName": index_name,
                "parentKeyFieldName": "parent_id",
                "sourceContext": "/document/pages/*",
                "mappings": [
                    {"name": "chunk", "source": "/document/pages/*"},
                    {"name": "text_vector", "source": "/document/pages/*/text_vector"},
                    {"name": "title", "source": "/document/metadata_storage_name"},
                ],
            }],
            "parameters": {"projectionMode": "skipIndexingParentDocuments"},
        },
    }


def build_indexer(name: str, data_source: str, skillset: str, index_name: str) -> dict:
    return {
        "name": name,
        "dataSourceName": data_source,
        "skillsetName": skillset,
        "targetIndexName": index_name,
        "parameters": {
            "configuration": {
                "dataToExtract": "contentAndMetadata",
                "parsingMode": "default",
            },
        },
        # Re-run hourly so newly uploaded documents get indexed automatically.
        "schedule": {"interval": "PT1H"},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Provision the Ask Maya AI Search pipeline.")
    parser.add_argument("--run", action="store_true", help="Run the indexer after setup.")
    args = parser.parse_args()

    search_endpoint = _env("AZURE_SEARCH_ENDPOINT")
    index_name = _env("AZURE_SEARCH_INDEX", "askmaya-index")
    aoai_endpoint = _env("AZURE_OPENAI_ENDPOINT")
    embedding_deployment = _env("AZURE_OPENAI_EMBEDDING_DEPLOYMENT", "text-embedding-3-small")
    storage_resource_id = _env("AZURE_STORAGE_RESOURCE_ID")
    container = _env("AZURE_STORAGE_CONTAINER", "documents")

    _require({
        "AZURE_SEARCH_ENDPOINT": search_endpoint,
        "AZURE_OPENAI_ENDPOINT": aoai_endpoint,
        "AZURE_STORAGE_RESOURCE_ID": storage_resource_id,
    })

    ds_name = f"{index_name}-ds"
    skillset_name = f"{index_name}-skillset"
    indexer_name = f"{index_name}-indexer"

    admin = SearchAdmin(search_endpoint)

    print(f"Provisioning Ask Maya ingestion pipeline on {search_endpoint}")
    admin.put("indexes", index_name, build_index(index_name, aoai_endpoint, embedding_deployment))
    admin.put("datasources", ds_name, build_data_source(ds_name, storage_resource_id, container))
    admin.put("skillsets", skillset_name,
              build_skillset(skillset_name, index_name, aoai_endpoint, embedding_deployment))
    admin.put("indexers", indexer_name,
              build_indexer(indexer_name, ds_name, skillset_name, index_name))

    if args.run:
        admin.run_indexer(indexer_name)

    print("Done.")


if __name__ == "__main__":
    main()
