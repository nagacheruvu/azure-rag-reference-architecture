# Ask Maya — Azure-Native RAG Knowledge Base

A lean, resilient, **Azure managed-services (PaaS-first)** retrieval-augmented knowledge base
built around **Azure AI Foundry** (redesigned from a legacy hybrid AWS/Azure RAG application).

> Goal: collapse a hybrid Solr + Java + queue-based system into a managed RAG stack —
> favoring managed services over IaaS, with resiliency and scale across regions and
> environments.

## What's in this workspace

| Path | Contents |
|---|---|
| [`docs/`](docs/) | Architecture, capability map, feature-parity matrix, standards, review plan |
| [`docs/diagrams/`](docs/diagrams/) | Mermaid (`.mmd`) + draw.io (`.drawio`) diagrams |
| [`infra/`](infra/) | `azd` + Bicep infrastructure-as-code (one template, every environment) |
| [`src/api/`](src/api/) | Container Apps chat API stub — SSE streaming over the Foundry Agent |
| [`src/web/`](src/web/) | Static Web Apps React UI stub |
| [`azure.yaml`](azure.yaml) | `azd` service map (api + web) |

## Quick start (MVP path)

The "almost no code" path proves out scalability and cost with a **3-service MVP**
(Static Web App → Container App API → AI Foundry Agent + AI Search + Cosmos serverless).

```bash
# 1. Provision + deploy everything (parameterized per environment)
azd auth login
azd up

# 2. Or smoke-test in the portal first:
#    AI Foundry → "Add your data" (Blob) → playground → "Deploy as a web app"
```

See [`docs/03-mvp-stack.md`](docs/03-mvp-stack.md) for the full MVP walkthrough and the
cheap, consumption-based tiers used for load/cost testing.

## Target architecture (summary)

- **Ingestion:** Blob → Document Intelligence → AI Search indexer + skillset (integrated
  vectorization) → vector index. Replaces Solr + custom embedding pipeline.
- **Query:** UI → APIM → Container Apps → **AI Foundry Agent** (grounded on AI Search) →
  `gpt-4o-mini`, streamed back over **SSE** with citations. History in **Cosmos DB**.
- **Removed:** Output Chunks Queue, WebSocket connection-routing, long-polling, Solr, the
  Java conversation engine, AWS Parameter Store, Splunk.

Full detail: [`docs/01-architecture.md`](docs/01-architecture.md).

## Document index

1. [Why simplify + current→target mapping](docs/02-current-to-target.md)
2. [Target architecture (full)](docs/01-architecture.md)
3. [Minimal viable stack](docs/03-mvp-stack.md)
4. [Feature-parity matrix](docs/04-feature-parity-matrix.md)
5. [Ready-made sample apps](docs/05-sample-apps.md)
6. [One-week review — framing](docs/06-one-week-review.md)
7. [Industry standards & frameworks](docs/07-industry-standards.md)
8. [Agnostic capability map](docs/08-capability-map.md)
9. [Open decisions](docs/09-open-decisions.md)
10. [Architecture patterns & guidance (simple / NSP / private cross-region)](docs/10-architecture-patterns.md)

## Contributing

This project welcomes contributions and suggestions. Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.opensource.microsoft.com.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft
trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.
