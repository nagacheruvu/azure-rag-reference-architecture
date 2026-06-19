"""Retrieval-augmented grounding against Azure AI Search.

Embeds the user question once (the embedding is reused by the semantic cache), runs a vector
query, and returns numbered context blocks plus citation metadata. Degrades gracefully: if the
index/endpoint is not configured or a query fails, returns empty context and the model answers
ungrounded rather than erroring.
"""

from __future__ import annotations

import numpy as np

from .azure_clients import openai_client, search_client
from .config import settings


def embed(text: str) -> np.ndarray:
    resp = openai_client().embeddings.create(
        model=settings.azure_openai_embedding_deployment,
        input=text,
    )
    return np.asarray(resp.data[0].embedding, dtype=np.float32)


def retrieve(question: str, embedding: np.ndarray) -> tuple[str, list[dict]]:
    client = search_client()
    if client is None:
        return "", []

    blocks: list[str] = []
    sources: list[dict] = []
    try:
        from azure.search.documents.models import VectorizedQuery

        vector_query = VectorizedQuery(
            vector=embedding.tolist(),
            k_nearest_neighbors=settings.azure_search_top_k,
            fields=settings.azure_search_vector_field,
        )
        results = client.search(
            search_text=question,  # hybrid: keyword + vector
            vector_queries=[vector_query],
            top=settings.azure_search_top_k,
        )
        # NOTE: `results` is a lazy SearchItemPaged — the HTTP request (and any auth/paging
        # error) only fires while iterating, so iteration MUST stay inside this try/except.
        # Otherwise a failed page fetch escapes as an uncaught _get_next(continuation_token)
        # error and kills the SSE stream, hanging the client.
        for i, doc in enumerate(results, start=1):
            content = doc.get(settings.azure_search_content_field) or ""
            title = doc.get(settings.azure_search_title_field) or f"Source {i}"
            if not content:
                continue
            blocks.append(f"[{i}] {title}\n{content}")
            sources.append({"id": i, "title": title})
    except Exception:  # noqa: BLE001 — never let retrieval break the chat path.
        return "", []

    return "\n\n".join(blocks), sources
