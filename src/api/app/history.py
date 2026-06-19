"""Cosmos DB persistence for chat turns and per-session conversation state.

We store the Responses API `previous_response_id` against the session so the *next* turn can
continue the conversation server-side at Azure OpenAI — meaning we never resend the full
transcript. That keeps input tokens (and cost) flat as a conversation grows, instead of
ballooning linearly with history length.
"""

from __future__ import annotations

import time
import uuid

from .azure_clients import cosmos_container


def get_previous_response_id(session_id: str) -> str | None:
    try:
        # cosmos_container() constructs the client and eagerly contacts Cosmos, so a firewall
        # block / outage raises HERE — keep it inside the try so it degrades to "fresh
        # conversation" rather than crashing the SSE stream.
        container = cosmos_container()
        if container is None:
            return None
        item = container.read_item(item=f"state:{session_id}", partition_key=session_id)
        return item.get("previousResponseId")
    except Exception:  # noqa: BLE001 — missing state just means a fresh conversation.
        return None


def count_questions(session_id: str) -> int:
    """Number of completed question/answer turns in this thread (for the per-thread cap)."""
    try:
        # cosmos_container() contacts Cosmos eagerly; keep it inside the try so a firewall
        # block doesn't crash the chat — fail open (0) so the user is never wrongly throttled.
        container = cosmos_container()
        if container is None:
            return 0
        items = list(
            container.query_items(
                query="SELECT VALUE COUNT(1) FROM c WHERE c.sessionId=@sid AND c.type='turn'",
                parameters=[{"name": "@sid", "value": session_id}],
                partition_key=session_id,
            )
        )
        return int(items[0]) if items else 0
    except Exception:  # noqa: BLE001 — if counting fails, don't block the user.
        return 0


def save_turn(
    session_id: str,
    question: str,
    answer: str,
    response_id: str | None,
    sources: list,
    cache_hit: str | None,
) -> None:
    now = int(time.time())
    try:
        # cosmos_container() contacts Cosmos eagerly; keep it inside the try so persistence
        # stays best-effort and a firewall block never breaks the response path.
        container = cosmos_container()
        if container is None:
            return
        container.upsert_item(
            {
                "id": f"turn:{session_id}:{uuid.uuid4().hex}",
                "sessionId": session_id,
                "type": "turn",
                "question": question,
                "answer": answer,
                "sources": sources,
                "cacheHit": cache_hit,
                "createdAt": now,
            }
        )
        if response_id:
            container.upsert_item(
                {
                    "id": f"state:{session_id}",
                    "sessionId": session_id,
                    "type": "state",
                    "previousResponseId": response_id,
                    "updatedAt": now,
                }
            )
    except Exception:  # noqa: BLE001 — persistence is best-effort, not on the hot path.
        pass
