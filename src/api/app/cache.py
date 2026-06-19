"""Two-tier answer cache that cuts token spend at scale.

Tier 1 — exact cache (optional, Redis-backed): normalized-question -> answer. Shared across
         all replicas, O(1), survives restarts. Catches identical repeated questions.
Tier 2 — semantic cache (in-process): cosine similarity over recent question embeddings.
         Catches paraphrases ("What is X?" vs "Tell me about X") without an LLM call.

A cache hit skips the chat-completion call entirely — the single biggest cost lever for a
high-traffic knowledge base where many users ask overlapping questions. The chat model is the
dominant token cost; embeddings (used to probe the cache) are ~orders of magnitude cheaper.
"""

from __future__ import annotations

import hashlib
import threading
import time
from dataclasses import dataclass, field

import numpy as np

from .config import settings

try:  # Redis is optional — absent => Tier 1 disabled, Tier 2 still works.
    import redis as _redis
except ImportError:  # pragma: no cover
    _redis = None


def _normalize(question: str) -> str:
    return " ".join(question.lower().split())


def _key(question: str) -> str:
    return "agc:" + hashlib.sha256(_normalize(question).encode()).hexdigest()


@dataclass
class _Entry:
    embedding: np.ndarray
    answer: str
    sources: list
    ts: float = field(default_factory=time.time)


class AnswerCache:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._entries: list[_Entry] = []
        self._redis = self._connect_redis()

    def _connect_redis(self):
        if not settings.redis_endpoint or _redis is None:
            return None
        try:
            client = _redis.Redis(
                host=settings.redis_endpoint,
                port=settings.redis_port,
                ssl=settings.redis_ssl,
                decode_responses=True,
                socket_timeout=1.5,
            )
            client.ping()
            return client
        except Exception:  # noqa: BLE001 — cache must never break the request path.
            return None

    # --- read ----------------------------------------------------------------
    def lookup(self, question: str, embedding: np.ndarray) -> dict | None:
        if not settings.semantic_cache_enabled:
            return None

        # Tier 1: exact, cross-replica.
        if self._redis is not None:
            try:
                hit = self._redis.hgetall(_key(question))
                if hit:
                    import json

                    return {
                        "answer": hit["answer"],
                        "sources": json.loads(hit.get("sources", "[]")),
                        "cache": "exact",
                    }
            except Exception:  # noqa: BLE001
                pass

        # Tier 2: semantic, in-process.
        best, best_score = None, 0.0
        cutoff = time.time() - settings.semantic_cache_ttl_seconds
        with self._lock:
            for entry in self._entries:
                if entry.ts < cutoff:
                    continue
                score = _cosine(embedding, entry.embedding)
                if score > best_score:
                    best, best_score = entry, score
        if best is not None and best_score >= settings.semantic_cache_threshold:
            return {
                "answer": best.answer,
                "sources": best.sources,
                "cache": "semantic",
                "score": round(best_score, 4),
            }
        return None

    # --- write ---------------------------------------------------------------
    def store(self, question: str, embedding: np.ndarray, answer: str, sources: list) -> None:
        if not settings.semantic_cache_enabled or not answer:
            return

        with self._lock:
            self._entries.append(_Entry(embedding=embedding, answer=answer, sources=sources))
            if len(self._entries) > settings.semantic_cache_max_entries:
                self._entries = self._entries[-settings.semantic_cache_max_entries :]

        if self._redis is not None:
            try:
                import json

                self._redis.hset(
                    _key(question),
                    mapping={"answer": answer, "sources": json.dumps(sources)},
                )
                self._redis.expire(_key(question), settings.semantic_cache_ttl_seconds)
            except Exception:  # noqa: BLE001
                pass


def _cosine(a: np.ndarray, b: np.ndarray) -> float:
    denom = float(np.linalg.norm(a) * np.linalg.norm(b))
    if denom == 0.0:
        return 0.0
    return float(np.dot(a, b) / denom)


cache = AnswerCache()
