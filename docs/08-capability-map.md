# 8. Agnostic capability map (proposed L1/L2)

| L1 Capability | L2 Capabilities | Azure implementation |
|---|---|---|
| **Ingestion** | Document landing, parsing/OCR, chunking, embedding | Blob, Document Intelligence, AI Search skillset, AOAI embeddings |
| **Retrieval** | Vector search, hybrid search, semantic rerank, query rewrite | Azure AI Search (vector + semantic) |
| **Grounding / RAG** | Context assembly, citation, grounding policy | AI Foundry Agent Service |
| **Conversation** | Session mgmt, history, modes (precise/summary), streaming | Container Apps API + Cosmos DB + SSE |
| **Model Serving** | Model routing, load balancing, capacity/failover | APIM + AOAI Global Standard pool |
| **Governance / RAI** | Content safety, prompt-injection defense, evals, audit | Content Safety, App Insights, NIST/OWASP controls |
| **Observability** | Tracing, token metering, SLO/SLI, cost attribution | App Insights / Log Analytics |
| **Scaling / Resiliency** | Autoscale, multi-region, DR, backpressure | Front Door, Container Apps KEDA, Cosmos multi-region |
| **Security / Identity** | AuthN/Z, secrets, network isolation, zero trust | Entra ID, Managed Identity, Key Vault, Private Endpoints |
| **Config / Ops** | Env parity, feature flags, IaC | App Configuration, Bicep / `azd` |

A dark-theme draw.io version of this map (capability → application → technology layers,
ArchiMate-style) is in [`diagrams/capability-map.drawio`](diagrams/capability-map.drawio).
