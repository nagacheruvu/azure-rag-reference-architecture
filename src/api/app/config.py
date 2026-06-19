"""Central configuration loaded from environment variables.

Every value maps to an env var injected by the Container App (see infra/resources.bicep)
or an azd `.env` file for local runs. Nothing here holds a secret — auth is managed-identity
based (DefaultAzureCredential), so we only carry endpoints and tuning knobs.
"""

from __future__ import annotations

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # --- Identity -------------------------------------------------------------
    # Set on the Container App to the user-assigned identity's client id so
    # DefaultAzureCredential picks the right identity. Empty locally (uses az login).
    azure_client_id: str = ""

    # --- Azure OpenAI ---------------------------------------------------------
    azure_openai_endpoint: str = ""
    azure_openai_chat_deployment: str = "gpt-5.4-mini"
    azure_openai_embedding_deployment: str = "text-embedding-3-small"
    # Responses API requires a recent preview/GA api-version.
    azure_openai_api_version: str = "2025-04-01-preview"

    # --- Azure AI Search (RAG grounding) -------------------------------------
    azure_search_endpoint: str = ""
    azure_search_index: str = "askmaya-index"
    azure_search_vector_field: str = "text_vector"
    azure_search_content_field: str = "chunk"
    azure_search_title_field: str = "title"
    azure_search_top_k: int = 5

    # --- Cosmos DB (chat history + session -> previous_response_id) -----------
    azure_cosmos_endpoint: str = ""
    azure_cosmos_database: str = "askmaya"
    azure_cosmos_container: str = "chat_history"

    # --- Caching --------------------------------------------------------------
    # Optional Redis (Azure Cache for Redis) backing the semantic cache so it is
    # shared across replicas. Empty => in-process cache (fine for a single replica MVP).
    redis_endpoint: str = ""
    redis_port: int = 6380
    redis_ssl: bool = True
    # Cosine-similarity threshold above which a cached answer is reused.
    semantic_cache_threshold: float = 0.95
    semantic_cache_ttl_seconds: int = 86_400
    semantic_cache_max_entries: int = 2_000
    semantic_cache_enabled: bool = True

    # --- Modes & thread limits ------------------------------------------------
    # Two answer modes:
    #   summary  -> LLM summarizes/synthesizes the research collateral (client launch mode).
    #   precise  -> answers strictly limited to document references (built, NOT released to
    #               clients yet — gated behind precise_mode_enabled).
    precise_mode_enabled: bool = False
    # A thread is capped at this many questions; each question is capped at this many chars.
    max_questions_per_thread: int = 5
    max_question_chars: int = 500

    # --- Behaviour ------------------------------------------------------------
    # Summary mode: synthesize a concise answer from the research collateral.
    system_prompt: str = (
        "You are Ask Maya, an enterprise research assistant. "
        "Summarize and synthesize an answer from the provided research sources, citing them "
        "as [1], [2] matching the numbered context. You may connect points across sources to "
        "give a clear, concise summary. If the sources do not address the question, say so "
        "plainly rather than guessing. Be neutral and analytical."
    )
    # Precise mode: answer ONLY from the exact document references, no synthesis.
    precise_system_prompt: str = (
        "You are Ask Maya in precise mode. Answer ONLY using the facts and wording found in the "
        "provided document references, and cite them as [1], [2]. Do not summarize, infer, "
        "paraphrase loosely, or add outside knowledge. If the references do not contain a direct "
        "answer, reply exactly: 'No matching document reference was found.'"
    )

    # --- Telemetry ------------------------------------------------------------
    applicationinsights_connection_string: str = ""


settings = Settings()
