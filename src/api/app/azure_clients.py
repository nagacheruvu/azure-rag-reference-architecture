"""Lazily-constructed Azure SDK clients, all authenticated with managed identity.

Per the deployment notes, service-principal data-plane calls are blocked tenant-wide, so
runtime auth relies on a user-assigned managed identity in the cloud (AZURE_CLIENT_ID) and
the cached `az login` token locally. DefaultAzureCredential handles both transparently.
"""

from __future__ import annotations

from functools import lru_cache

from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from azure.cosmos import CosmosClient
from azure.search.documents import SearchClient
from openai import AzureOpenAI

from .config import settings

_COGNITIVE_SCOPE = "https://cognitiveservices.azure.com/.default"


@lru_cache(maxsize=1)
def credential() -> DefaultAzureCredential:
    # managed_identity_client_id makes the user-assigned identity unambiguous in the cloud.
    return DefaultAzureCredential(
        managed_identity_client_id=settings.azure_client_id or None,
    )


@lru_cache(maxsize=1)
def openai_client() -> AzureOpenAI:
    token_provider = get_bearer_token_provider(credential(), _COGNITIVE_SCOPE)
    return AzureOpenAI(
        azure_endpoint=settings.azure_openai_endpoint,
        api_version=settings.azure_openai_api_version,
        azure_ad_token_provider=token_provider,
    )


@lru_cache(maxsize=1)
def search_client() -> SearchClient | None:
    if not settings.azure_search_endpoint:
        return None
    return SearchClient(
        endpoint=settings.azure_search_endpoint,
        index_name=settings.azure_search_index,
        credential=credential(),
    )


@lru_cache(maxsize=1)
def cosmos_container():
    if not settings.azure_cosmos_endpoint:
        return None
    client = CosmosClient(settings.azure_cosmos_endpoint, credential=credential())
    db = client.get_database_client(settings.azure_cosmos_database)
    return db.get_container_client(settings.azure_cosmos_container)
