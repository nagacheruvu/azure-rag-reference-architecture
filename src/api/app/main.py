"""Ask Maya chat API.

Request flow (the cost-efficient path the redesign is built around):

  1. Embed the question once  -> reused for both the cache probe and RAG retrieval.
  2. Semantic / exact cache    -> on hit, stream the cached answer, ZERO chat-model tokens.
  3. RAG retrieve (AI Search)  -> numbered, citable context.
  4. Responses API call        -> stateful via `previous_response_id` (context memory) and
                                  prompt-cached system instructions (stable prefix). Streamed
                                  back to the browser over Server-Sent Events.
  5. Persist turn + cache the answer for the next caller.
"""

from __future__ import annotations

import json
import uuid

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from .cache import cache
from .config import settings
from .azure_clients import openai_client
from .history import count_questions, get_previous_response_id, save_turn
from .rag import embed, retrieve

app = FastAPI(title="Ask Maya API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


class ChatRequest(BaseModel):
    message: str
    sessionId: str | None = None
    # "summary" (client launch mode) or "precise" (gated by precise_mode_enabled).
    mode: str = "summary"


def _sse(event: dict) -> str:
    return f"data: {json.dumps(event)}\n\n"


def _is_throttled(exc: Exception) -> bool:
    """True when an exception represents service throttling (HTTP 429 / rate limit)."""
    status = getattr(exc, "status_code", None) or getattr(
        getattr(exc, "response", None), "status_code", None
    )
    if status == 429:
        return True
    text = str(exc).lower()
    return "429" in text or "rate limit" in text or "too many requests" in text


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/config")
def config() -> dict:
    """Client-facing capabilities + limits (single source of truth for the UI)."""
    return {
        "preciseModeEnabled": settings.precise_mode_enabled,
        "maxQuestionsPerThread": settings.max_questions_per_thread,
        "maxQuestionChars": settings.max_question_chars,
    }


@app.post("/chat")
def chat(req: ChatRequest) -> StreamingResponse:
    session_id = req.sessionId or uuid.uuid4().hex
    question = req.message.strip()
    # Precise mode is gated; until released, requests for it fall back to summary.
    mode = req.mode if req.mode in ("summary", "precise") else "summary"
    if mode == "precise" and not settings.precise_mode_enabled:
        mode = "summary"

    def stream():
        yield _sse({"type": "session", "sessionId": session_id})

        # Guard: per-question character cap.
        if len(question) > settings.max_question_chars:
            yield _sse(
                {
                    "type": "limit",
                    "scope": "length",
                    "message": f"Questions are limited to {settings.max_question_chars} characters.",
                }
            )
            return

        # Guard: per-thread question cap.
        if count_questions(session_id) >= settings.max_questions_per_thread:
            yield _sse(
                {
                    "type": "limit",
                    "scope": "thread",
                    "message": (
                        f"You've reached the {settings.max_questions_per_thread}-question limit "
                        "for this thread. Start a new thread to continue."
                    ),
                }
            )
            return

        # 1. One embedding, reused by the cache probe and retrieval.
        try:
            embedding = embed(question)
        except Exception as exc:  # noqa: BLE001
            if _is_throttled(exc):
                yield _sse(
                    {
                        "type": "busy",
                        "message": "Ask Maya is experiencing high demand. Please try again in a few minutes.",
                    }
                )
            else:
                yield _sse({"type": "error", "message": str(exc)})
            return

        # 2. Cache short-circuit: a hit means no chat-model tokens are spent at all.
        cached = cache.lookup(question, embedding)
        if cached is not None:
            yield _sse({"type": "token", "text": cached["answer"]})
            yield _sse(
                {
                    "type": "done",
                    "sources": cached.get("sources", []),
                    "cache": cached.get("cache"),
                    "score": cached.get("score"),
                }
            )
            save_turn(session_id, question, cached["answer"], None, cached.get("sources", []), cached.get("cache"))
            return

        # 3. Ground the answer.
        context, sources = retrieve(question, embedding)
        if sources:
            yield _sse({"type": "sources", "sources": sources})

        # Precise mode with no grounding => deterministic refusal, no model tokens spent.
        if mode == "precise" and not context:
            refusal = "No matching document reference was found."
            yield _sse({"type": "token", "text": refusal})
            yield _sse({"type": "done", "sources": [], "cache": None})
            save_turn(session_id, question, refusal, None, [], None)
            return

        user_input = (
            f"Context sources:\n{context}\n\nQuestion: {question}"
            if context
            else question
        )

        # 4. Stateful, streamed completion. `previous_response_id` carries the conversation
        #    server-side, so we send only this turn's input (flat token cost as chat grows).
        instructions = (
            settings.precise_system_prompt if mode == "precise" else settings.system_prompt
        )
        kwargs = {
            "model": settings.azure_openai_chat_deployment,
            "instructions": instructions,  # stable per-mode prefix -> prompt cache discount
            "input": user_input,
            "store": True,
            "stream": True,
        }
        if mode == "precise":
            kwargs["temperature"] = 0.0  # extractive, no creative drift
        prev = get_previous_response_id(session_id)
        if prev:
            kwargs["previous_response_id"] = prev

        answer_parts: list[str] = []
        response_id: str | None = None
        try:
            for event in openai_client().responses.create(**kwargs):
                etype = getattr(event, "type", "")
                if etype == "response.output_text.delta":
                    delta = getattr(event, "delta", "")
                    if delta:
                        answer_parts.append(delta)
                        yield _sse({"type": "token", "text": delta})
                elif etype in ("response.created", "response.completed"):
                    response_id = getattr(getattr(event, "response", None), "id", response_id)
                elif etype == "response.error":
                    yield _sse({"type": "error", "message": "model error"})
        except Exception as exc:  # noqa: BLE001 — surface a clean error to the client.
            if _is_throttled(exc):
                yield _sse(
                    {
                        "type": "busy",
                        "message": "Ask Maya is experiencing high demand. Please try again in a few minutes.",
                    }
                )
            else:
                yield _sse({"type": "error", "message": str(exc)})
            return

        answer = "".join(answer_parts)
        yield _sse({"type": "done", "sources": sources, "cache": None})

        # 5. Persist + populate cache for the next caller.
        save_turn(session_id, question, answer, response_id, sources, None)
        cache.store(question, embedding, answer, sources)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
