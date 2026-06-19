"""
In-VNet end-to-end validator for the Foundry agent -> private MCP path.

Runs as an Azure Container Apps Job inside the SAME internal ACA environment as
the MCP server (subnet snet-mcp), so it can reach the Foundry project endpoint
(publicNetworkAccess=Disabled) over the private endpoint, and resolve the ACA
internal FQDN via the private DNS zone linked to the VNet.

It proves the full path:
    test client (in-VNet)
        -> Foundry project endpoint (private)  -- create + run agent
            -> agent "data proxy" (network injection, snet-agent)
                -> private DNS resolves the ACA internal FQDN
                    -> MCP server (ACA internal ingress, snet-mcp) -- tool call
                        -> private sample dataset -> answer

Auth: user-assigned managed identity (MI_CLIENT_ID) granted Azure AI / Cognitive
Services data-plane roles on the Foundry account/project.

Emits a machine-readable result block to stdout between markers so the operator
can parse it and render an HTML report locally:

    ===E2E_RESULT_BEGIN===
    { ...json... }
    ===E2E_RESULT_END===
"""
from __future__ import annotations

import asyncio
import json
import os
import socket
import time
from datetime import datetime, timezone
from urllib.parse import urlparse

from azure.identity import ManagedIdentityCredential
from azure.ai.agents import AgentsClient
from azure.ai.agents.models import (
    McpTool,
    RequiredMcpToolCall,
    SubmitToolApprovalAction,
    ToolApproval,
)

PROJECT_ENDPOINT = os.environ["PROJECT_ENDPOINT"]
MCP_SERVER_URL = os.environ["MCP_SERVER_URL"]
MODEL_NAME = os.environ.get("MODEL_NAME", "gpt-4o-mini")
MI_CLIENT_ID = os.environ.get("MI_CLIENT_ID", "")
SERVER_LABEL = "askmaya_private_data"

# Expected facts from the private dataset (src/mcp-server/app.py).
EXPECT_WEST_REVENUE = 1_733_200
EXPECT_TOTAL_REVENUE = 5_105_900  # 1,284,500 + 982,300 + 1,105,900 + 1,733,200


def _is_private_ip(ip: str) -> bool:
    try:
        a, b, *_ = (int(p) for p in ip.split("."))
    except ValueError:
        return False
    # RFC1918 plus 100.64.0.0/10 (CGNAT) — the ACA internal mesh hands out
    # 100.100.x.x to in-env clients, which is still a non-routable private address.
    return (
        a == 10
        or (a == 172 and 16 <= b <= 31)
        or (a == 192 and b == 168)
        or (a == 100 and 64 <= b <= 127)
    )


def resolve(host: str) -> list[str]:
    try:
        infos = socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)
        return sorted({i[4][0] for i in infos})
    except Exception as exc:  # noqa: BLE001
        return [f"ERROR: {exc}"]


async def _probe_mcp_async() -> dict:
    """Directly exercise the MCP server (initialize -> tools/list -> tools/call)
    over Streamable HTTP, from inside the VNet. Proves the server + transport +
    in-VNet reachability independently of the Foundry data-proxy hop."""
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    out: dict = {"reachable": False, "tools": [], "west_revenue": None, "error": None}
    async with streamablehttp_client(MCP_SERVER_URL) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            out["reachable"] = True
            listed = await session.list_tools()
            out["tools"] = [t.name for t in listed.tools]
            called = await session.call_tool("get_region_sales", {"region": "west"})
            texts: list[str] = []
            for block in called.content or []:
                val = getattr(block, "text", None)
                if val:
                    texts.append(val)
            out["west_revenue"] = "\n".join(texts)
    return out


def probe_mcp() -> dict:
    try:
        return asyncio.run(_probe_mcp_async())
    except Exception as exc:  # noqa: BLE001
        return {"reachable": False, "tools": [], "west_revenue": None, "error": f"{type(exc).__name__}: {exc}"}


def _is_known_dataproxy_limitation(run_error: str | None) -> bool:
    """The Foundry data-proxy private-DNS limitation surfaces as HTTP 424 /
    'Failed Dependency' on the tools/list handshake. Documented in the official
    reference template 19-private-network-agent-tools tests."""
    if not run_error:
        return False
    e = run_error.lower()
    return "424" in e or "failed dependency" in e or "tool_server_error" in e


def main() -> int:
    result: dict = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "project_endpoint": PROJECT_ENDPOINT,
        "mcp_server_url": MCP_SERVER_URL,
        "model": MODEL_NAME,
        "dns": {},
        "mcp_probe": {},
        "agent_id": None,
        "run_status": None,
        "run_error": None,
        "dataproxy_known_limitation": False,
        "tool_calls": [],
        "final_answer": None,
        "checks": [],
        "overall_pass": False,
    }

    project_host = urlparse(PROJECT_ENDPOINT).hostname or ""
    mcp_host = urlparse(MCP_SERVER_URL).hostname or ""
    result["dns"][project_host] = resolve(project_host)
    result["dns"][mcp_host] = resolve(mcp_host)

    # --- Layer 1: direct MCP probe (server + transport + in-VNet reach) ------
    result["mcp_probe"] = probe_mcp()
    print(f"MCP probe: {json.dumps(result['mcp_probe'])}", flush=True)

    cred = ManagedIdentityCredential(client_id=MI_CLIENT_ID) if MI_CLIENT_ID else ManagedIdentityCredential()
    client = AgentsClient(endpoint=PROJECT_ENDPOINT, credential=cred)

    mcp_tool = McpTool(server_label=SERVER_LABEL, server_url=MCP_SERVER_URL, allowed_tools=[])

    with client:
        agent = client.create_agent(
            model=MODEL_NAME,
            name="askmaya-e2e-validator",
            instructions=(
                "You are a data analyst. Use the askmaya_private_data MCP tools to answer. "
                "Always call a tool rather than guessing. Report exact numbers."
            ),
            tools=mcp_tool.definitions,
        )
        result["agent_id"] = agent.id
        print(f"Created agent: {agent.id}", flush=True)

        thread = client.threads.create()
        client.messages.create(
            thread_id=thread.id,
            role="user",
            content=(
                "Using the tools, what was the revenue for the west region? "
                "Then give the total revenue summed across all regions. "
                "State both numbers explicitly."
            ),
        )

        try:
            mcp_tool.set_approval_mode("never")
        except Exception:  # noqa: BLE001
            pass

        run = client.runs.create(thread_id=thread.id, agent_id=agent.id, tool_resources=mcp_tool.resources)

        while run.status in ("queued", "in_progress", "requires_action"):
            time.sleep(2)
            run = client.runs.get(thread_id=thread.id, run_id=run.id)
            if run.status == "requires_action" and isinstance(run.required_action, SubmitToolApprovalAction):
                calls = run.required_action.submit_tool_approval.tool_calls or []
                approvals = []
                for c in calls:
                    if isinstance(c, RequiredMcpToolCall):
                        result["tool_calls"].append(
                            {"name": getattr(c, "name", None), "arguments": getattr(c, "arguments", None)}
                        )
                        approvals.append(ToolApproval(tool_call_id=c.id, approve=True, headers=mcp_tool.headers))
                if approvals:
                    client.runs.submit_tool_outputs(thread_id=thread.id, run_id=run.id, tool_approvals=approvals)

        result["run_status"] = run.status
        if getattr(run, "last_error", None):
            result["run_error"] = str(run.last_error)
        print(f"Run status: {run.status}", flush=True)

        # Best-effort: capture MCP tool-call steps for the report.
        try:
            for step in client.run_steps.list(thread_id=thread.id, run_id=run.id):
                sd = getattr(step, "step_details", None)
                for tc in getattr(sd, "tool_calls", []) or []:
                    entry = {"type": getattr(tc, "type", None), "name": getattr(tc, "name", None)}
                    if entry not in result["tool_calls"]:
                        result["tool_calls"].append(entry)
        except Exception:  # noqa: BLE001
            pass

        answer_parts: list[str] = []
        for msg in client.messages.list(thread_id=thread.id):
            role = getattr(msg, "role", None)
            role = getattr(role, "value", role)
            if role not in ("assistant", "agent"):
                continue
            # Preferred helper on the preview SDK.
            for tm in getattr(msg, "text_messages", []) or []:
                val = getattr(getattr(tm, "text", None), "value", None)
                if val:
                    answer_parts.append(val)
            # Fallback to raw content blocks.
            if not getattr(msg, "text_messages", None):
                for c in getattr(msg, "content", []) or []:
                    val = getattr(getattr(c, "text", None), "value", None)
                    if val:
                        answer_parts.append(val)
        result["final_answer"] = "\n".join(answer_parts).strip()

        try:
            client.delete_agent(agent.id)
        except Exception:  # noqa: BLE001
            pass

    # --- Validation checks --------------------------------------------------
    answer = (result["final_answer"] or "").replace(",", "").lower()

    def check(name: str, passed: bool, detail: str) -> None:
        result["checks"].append({"name": name, "passed": bool(passed), "detail": detail})

    proj_ips = result["dns"].get(project_host, [])
    mcp_ips = result["dns"].get(mcp_host, [])
    check(
        "Foundry project FQDN resolves to a private IP (in-VNet)",
        any(_is_private_ip(ip) for ip in proj_ips),
        f"{project_host} -> {proj_ips}",
    )
    check(
        "ACA internal MCP FQDN resolves to a private IP (private DNS)",
        any(_is_private_ip(ip) for ip in mcp_ips),
        f"{mcp_host} -> {mcp_ips}",
    )
    probe = result["mcp_probe"]
    check(
        "MCP server reachable in-VNet (Streamable HTTP initialize)",
        bool(probe.get("reachable")),
        probe.get("error") or f"tools={probe.get('tools')}",
    )
    check(
        "MCP tools/list returns the private data tools",
        "get_region_sales" in (probe.get("tools") or []),
        f"tools={probe.get('tools')}",
    )
    check(
        "MCP tools/call get_region_sales(west) returns 1,733,200",
        str(EXPECT_WEST_REVENUE) in (probe.get("west_revenue") or "").replace(",", ""),
        f"west_revenue={probe.get('west_revenue')}",
    )
    check("Agent run completed", result["run_status"] == "completed", f"run_status={result['run_status']}")
    check(
        "Agent invoked the private MCP tool (data-proxy -> private IP)",
        len(result["tool_calls"]) > 0,
        f"{len(result['tool_calls'])} tool call(s): {result['tool_calls']}",
    )
    check(
        "Answer contains west revenue 1,733,200",
        str(EXPECT_WEST_REVENUE) in answer,
        "looked for 1733200 in answer",
    )
    check(
        "Answer contains total revenue 5,105,900",
        str(EXPECT_TOTAL_REVENUE) in answer,
        "looked for 5105900 in answer",
    )

    # The Foundry data-proxy private-DNS limitation (HTTP 424) is a documented
    # platform constraint, not a misconfiguration. Record it explicitly so the
    # report can attribute the agent-path failure correctly.
    result["dataproxy_known_limitation"] = (
        result["run_status"] != "completed" and _is_known_dataproxy_limitation(result["run_error"])
    )

    # Infrastructure is validated end-to-end when DNS + the direct MCP path all
    # pass. The agent/data-proxy hop is reported but, when it hits the known 424
    # platform limitation, it does not invalidate the proven private path.
    infra_checks = result["checks"][:5]  # DNS x2 + MCP probe x3
    result["infra_pass"] = all(c["passed"] for c in infra_checks)
    result["overall_pass"] = all(c["passed"] for c in result["checks"])

    print("===E2E_RESULT_BEGIN===", flush=True)
    print(json.dumps(result, indent=2), flush=True)
    print("===E2E_RESULT_END===", flush=True)
    return 0 if result["overall_pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
