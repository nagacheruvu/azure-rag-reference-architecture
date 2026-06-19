"""
Create a Foundry agent wired to the private MCP server and prove the
agent -> private-MCP path by asking it to call a data tool.

Run AFTER:
  1) the Pass 2 bicep deploy (capability host created), and
  2) scripts/deploy_mcp_aca.ps1 (prints the internal MCP server URL).

Auth: AzureCliCredential (cached `az login` token) — SP data-plane is blocked
under MCAPS, so use the signed-in user.

Env vars:
  PROJECT_ENDPOINT   https://<account>.services.ai.azure.com/api/projects/<project>
  MCP_SERVER_URL     https://<aca-internal-fqdn>/mcp
  MODEL_NAME         deployed model name (default gpt-4o-mini)
"""
from __future__ import annotations

import os
import time

from azure.identity import AzureCliCredential
from azure.ai.agents import AgentsClient
from azure.ai.agents.models import McpTool, RequiredMcpToolCall, SubmitToolApprovalAction, ToolApproval

PROJECT_ENDPOINT = os.environ["PROJECT_ENDPOINT"]
MCP_SERVER_URL = os.environ["MCP_SERVER_URL"]
MODEL_NAME = os.environ.get("MODEL_NAME", "gpt-4o-mini")
SERVER_LABEL = "askmaya_private_data"

cred = AzureCliCredential()
client = AgentsClient(endpoint=PROJECT_ENDPOINT, credential=cred)

mcp_tool = McpTool(
    server_label=SERVER_LABEL,
    server_url=MCP_SERVER_URL,
    allowed_tools=[],  # empty = allow all tools the server advertises
)

with client:
    agent = client.create_agent(
        model=MODEL_NAME,
        name="askmaya-private-data-agent",
        instructions=(
            "You are a data analyst. Use the askmaya_private_data MCP tools to "
            "answer questions about regional sales and the product catalog. "
            "Always call a tool rather than guessing."
        ),
        tools=mcp_tool.definitions,
    )
    print(f"Created agent: {agent.id}")

    thread = client.threads.create()
    client.messages.create(
        thread_id=thread.id,
        role="user",
        content="What was revenue and YoY growth in the west region? Then give total revenue across all regions.",
    )

    # Auto-approve MCP tool calls (demo). In prod, gate this.
    mcp_tool.set_approval_mode("never")  # no per-call approval if supported
    run = client.runs.create(thread_id=thread.id, agent_id=agent.id, tool_resources=mcp_tool.resources)

    while run.status in ("queued", "in_progress", "requires_action"):
        time.sleep(2)
        run = client.runs.get(thread_id=thread.id, run_id=run.id)
        if run.status == "requires_action" and isinstance(run.required_action, SubmitToolApprovalAction):
            calls = run.required_action.submit_tool_approval.tool_calls or []
            approvals = [
                ToolApproval(tool_call_id=c.id, approve=True, headers=mcp_tool.headers)
                for c in calls
                if isinstance(c, RequiredMcpToolCall)
            ]
            if approvals:
                client.runs.submit_tool_outputs(thread_id=thread.id, run_id=run.id, tool_approvals=approvals)

    print(f"Run status: {run.status}")
    if run.last_error:
        print(f"Error: {run.last_error}")

    for msg in client.messages.list(thread_id=thread.id):
        for c in msg.content:
            if getattr(c, "text", None):
                print(f"[{msg.role}] {c.text.value}")

    client.delete_agent(agent.id)
    print("Deleted agent.")
