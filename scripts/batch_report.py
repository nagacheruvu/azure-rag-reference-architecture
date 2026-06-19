"""Detailed-report cost experiment: HIGH (sync GlobalStandard) vs LOW (async GlobalBatch).

Runs the *same* detailed-report prompt(s) through two lanes on the same model + region so the
only variable is the priority lane:

  HIGH priority  -> gpt-5.1-standard  (GlobalStandard, synchronous)   = full price, seconds
  LOW  priority  -> gpt-5.1-batch     (GlobalBatch, async JSONL job)  = ~50% price, up to 24h

It captures real token usage from each lane and computes cost from a configurable price table.
Per Azure docs, Batch is billed at 50% of the Global Standard rate, so the LOW lane cost is the
measured batch tokens * (standard rate * BATCH_DISCOUNT).

Auth: uses AzureCliCredential (cached `az login` token). Service-principal data-plane calls are
blocked tenant-wide, so we deliberately rely on the user token for this local script.

Usage (PowerShell):
  $env:PYTHONIOENCODING="utf-8"
  python scripts/batch_report.py --poll          # full run, polls the batch job to completion
  python scripts/batch_report.py --high-only     # just the sync lane (fast smoke test)
"""

from __future__ import annotations

import argparse
import json
import time
from dataclasses import dataclass, field

from azure.identity import AzureCliCredential, get_bearer_token_provider
from openai import AzureOpenAI

# --------------------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------------------
ENDPOINT = "https://azcogbatchamdev01.openai.azure.com/"
API_VERSION = "2025-04-01-preview"
STANDARD_DEPLOYMENT = "gpt-5.1-standard"  # GlobalStandard (HIGH / sync lane)
BATCH_DEPLOYMENT = "gpt-5.1-batch"        # GlobalBatch    (LOW  / async lane)

# Price per 1M tokens (USD). Configurable — retail API does not yet expose gpt-5.1 meters in
# this tenant, so these are realistic gpt-5-class placeholders. The cost *delta* is driven by
# the documented batch discount, not the absolute number.
PRICE_PER_1M_INPUT = 1.25
PRICE_PER_1M_OUTPUT = 10.00
BATCH_DISCOUNT = 0.50  # Azure Batch is billed at 50% of Global Standard.

# The "detailed report" workload: summarize/analyze source documents. Mirrors Ask Maya's
# detailed-report path (document review and summarization), which is exactly the Batch use case.
SOURCE_DOCS = [
    (
        "Maya-Magic-Quadrant-iPaaS-2026",
        "Enterprise integration platform as a service (iPaaS) adoption accelerated in 2026 as "
        "organizations consolidated point-to-point integrations onto governed, API-led platforms. "
        "Leaders differentiated on AI-assisted mapping, event-driven patterns, and FinOps-grade "
        "cost observability. Buyers increasingly demanded prebuilt connectors, low-code citizen "
        "developer experiences, and strong data residency controls. Challengers lagged on "
        "multi-region resilience and unified token-level cost telemetry for embedded GenAI features.",
    ),
    (
        "Forrester-Wave-Conversational-AI-2026",
        "Conversational AI platforms matured toward retrieval-grounded assistants with strict "
        "citation requirements to curb hallucination. Differentiators included semantic caching to "
        "cut inference cost, priority-based routing between provisioned and shared capacity, and "
        "policy-enforced token budgets per consumer. Vendors that exposed per-conversation token "
        "metrics and content-safety gating scored highest on trust and governance.",
    ),
]

REPORT_INSTRUCTION = (
    "You are an analyst. Produce a detailed structured report on the document below. "
    "Include: (1) an executive summary, (2) key findings as bullet points, (3) risks and "
    "open questions, and (4) three concrete recommendations. Ground every claim in the text."
)


def build_messages(doc_title: str, doc_body: str) -> list[dict]:
    return [
        {"role": "system", "content": REPORT_INSTRUCTION},
        {"role": "user", "content": f"# {doc_title}\n\n{doc_body}"},
    ]


# --------------------------------------------------------------------------------------
# Cost helpers
# --------------------------------------------------------------------------------------
@dataclass
class LaneResult:
    lane: str
    deployment: str
    prompt_tokens: int = 0
    completion_tokens: int = 0
    wall_seconds: float = 0.0
    discount: float = 0.0
    reports: list[str] = field(default_factory=list)

    @property
    def total_tokens(self) -> int:
        return self.prompt_tokens + self.completion_tokens

    @property
    def cost(self) -> float:
        base = (
            self.prompt_tokens / 1_000_000 * PRICE_PER_1M_INPUT
            + self.completion_tokens / 1_000_000 * PRICE_PER_1M_OUTPUT
        )
        return base * (1.0 - self.discount)


def client() -> AzureOpenAI:
    token_provider = get_bearer_token_provider(
        AzureCliCredential(), "https://cognitiveservices.azure.com/.default"
    )
    return AzureOpenAI(
        azure_endpoint=ENDPOINT,
        api_version=API_VERSION,
        azure_ad_token_provider=token_provider,
    )


# --------------------------------------------------------------------------------------
# HIGH lane — synchronous GlobalStandard
# --------------------------------------------------------------------------------------
def run_high(cli: AzureOpenAI) -> LaneResult:
    res = LaneResult(lane="HIGH (sync)", deployment=STANDARD_DEPLOYMENT, discount=0.0)
    start = time.monotonic()
    for title, body in SOURCE_DOCS:
        resp = cli.chat.completions.create(
            model=STANDARD_DEPLOYMENT,
            messages=build_messages(title, body),
            max_completion_tokens=1200,
        )
        res.prompt_tokens += resp.usage.prompt_tokens
        res.completion_tokens += resp.usage.completion_tokens
        res.reports.append(resp.choices[0].message.content or "")
    res.wall_seconds = time.monotonic() - start
    return res


# --------------------------------------------------------------------------------------
# LOW lane — asynchronous GlobalBatch (JSONL job)
# --------------------------------------------------------------------------------------
def run_low(cli: AzureOpenAI, poll: bool, poll_interval: int, max_wait: int) -> LaneResult:
    res = LaneResult(lane="LOW (batch)", deployment=BATCH_DEPLOYMENT, discount=BATCH_DISCOUNT)

    # 1. Build the JSONL request file (one line per document).
    lines = []
    for i, (title, body) in enumerate(SOURCE_DOCS):
        lines.append(
            json.dumps(
                {
                    "custom_id": f"report-{i}",
                    "method": "POST",
                    "url": "/chat/completions",
                    "body": {
                        "model": BATCH_DEPLOYMENT,
                        "messages": build_messages(title, body),
                        "max_completion_tokens": 1200,
                    },
                }
            )
        )
    jsonl_bytes = ("\n".join(lines) + "\n").encode("utf-8")

    # 2. Upload + submit the batch job.
    upload = cli.files.create(file=("batch_report.jsonl", jsonl_bytes), purpose="batch")
    job = cli.batches.create(
        input_file_id=upload.id,
        endpoint="/chat/completions",
        completion_window="24h",
    )
    print(f"  batch job submitted: id={job.id} status={job.status}")

    if not poll:
        print("  --poll not set: not waiting. Retrieve later with --resume <job_id>.")
        res.reports.append(f"[pending] job_id={job.id}")
        return res

    # 3. Poll to completion (Batch target is 24h but small jobs often finish in minutes).
    deadline = time.monotonic() + max_wait
    start = time.monotonic()
    while time.monotonic() < deadline:
        job = cli.batches.retrieve(job.id)
        print(f"  batch status: {job.status}  (completed={job.request_counts.completed}/"
              f"{job.request_counts.total})")
        if job.status in ("completed", "failed", "expired", "cancelled"):
            break
        time.sleep(poll_interval)
    res.wall_seconds = time.monotonic() - start

    if job.status != "completed":
        res.reports.append(f"[job ended: {job.status}] id={job.id}")
        return res

    # 4. Retrieve + parse the output JSONL (usage is per line).
    content = cli.files.content(job.output_file_id).read().decode("utf-8")
    for raw in content.splitlines():
        if not raw.strip():
            continue
        rec = json.loads(raw)
        body = rec.get("response", {}).get("body", {})
        usage = body.get("usage", {})
        res.prompt_tokens += usage.get("prompt_tokens", 0)
        res.completion_tokens += usage.get("completion_tokens", 0)
        choices = body.get("choices", [])
        if choices:
            res.reports.append(choices[0]["message"]["content"])
    return res


# --------------------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------------------
def print_comparison(high: LaneResult | None, low: LaneResult | None) -> None:
    print("\n" + "=" * 78)
    print("COST METRICS — detailed report: LOW (batch) vs HIGH (standard)")
    print("=" * 78)
    header = f"{'metric':<24}{'HIGH (sync)':>26}{'LOW (batch)':>26}"
    print(header)
    print("-" * 78)

    def row(label, h, l):
        print(f"{label:<24}{h:>26}{l:>26}")

    h_pt = high.prompt_tokens if high else 0
    h_ct = high.completion_tokens if high else 0
    l_pt = low.prompt_tokens if low else 0
    l_ct = low.completion_tokens if low else 0

    row("deployment", high.deployment if high else "-", low.deployment if low else "-")
    row("prompt tokens", h_pt, l_pt)
    row("completion tokens", h_ct, l_ct)
    row("total tokens", (h_pt + h_ct), (l_pt + l_ct))
    row("billing discount", "0%", f"{int(BATCH_DISCOUNT*100)}%")
    if high:
        row("wall time (s)", f"{high.wall_seconds:.1f}", "")
    if low and low.wall_seconds:
        row("wall time (s)", "", f"{low.wall_seconds:.1f}")
    row("cost (USD)", f"${high.cost:.6f}" if high else "-",
        f"${low.cost:.6f}" if low else "-")

    if high and low and high.cost > 0:
        savings = (1 - low.cost / high.cost) * 100 if high.cost else 0
        print("-" * 78)
        print(f"{'LOW vs HIGH savings':<24}{'':>26}{f'{savings:.1f}% cheaper':>26}")
    print("=" * 78)
    print(f"\nPrice table (per 1M tokens): input=${PRICE_PER_1M_INPUT}  "
          f"output=${PRICE_PER_1M_OUTPUT}  batch_discount={int(BATCH_DISCOUNT*100)}%")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--high-only", action="store_true", help="run only the sync lane")
    ap.add_argument("--low-only", action="store_true", help="run only the batch lane")
    ap.add_argument("--poll", action="store_true", help="poll the batch job to completion")
    ap.add_argument("--poll-interval", type=int, default=30, help="seconds between polls")
    ap.add_argument("--max-wait", type=int, default=3600, help="max seconds to wait for batch")
    ap.add_argument("--show-reports", action="store_true", help="print generated reports")
    args = ap.parse_args()

    cli = client()
    high = low = None

    if not args.low_only:
        print("\n[HIGH] running synchronous GlobalStandard lane...")
        high = run_high(cli)
        print(f"[HIGH] done in {high.wall_seconds:.1f}s, {high.total_tokens} tokens")

    if not args.high_only:
        print("\n[LOW] submitting GlobalBatch lane...")
        low = run_low(cli, args.poll, args.poll_interval, args.max_wait)

    print_comparison(high, low)

    if args.show_reports:
        for lane in (high, low):
            if not lane:
                continue
            print(f"\n\n##### {lane.lane} reports #####")
            for i, r in enumerate(lane.reports):
                print(f"\n--- report {i} ---\n{r}")


if __name__ == "__main__":
    main()
