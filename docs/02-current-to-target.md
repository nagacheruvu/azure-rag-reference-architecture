# 2. Why simplify + current → target mapping

The current **Ask Maya** system is a hybrid setup: AWS for most components, Azure OpenAI
for LLM calls, a React front end, a Java back end, a queue-based request manager, and a
Solr vector database for proprietary data + embeddings. The goal is to collapse this into a
lean, Azure-native, PaaS-first RAG knowledge base built around **Azure AI Foundry**,
favoring **managed services over IaaS**, with resiliency and scale across regions and
environments.

## Current → Target mapping (complexity drivers)

| Current (hybrid / IaaS / custom) | Target (Azure managed / PaaS) | Why |
|---|---|---|
| Solr vector DB + custom embedding pipeline | **Azure AI Search** (integrated vectorization + indexers) | Built-in chunking, embedding, hybrid + semantic ranking — no Solr to run |
| Java conversation logic + priority/standard & precise/summary queues | **Azure AI Foundry Agent Service** (Knowledge Base agent) | Agent orchestration, grounding, citations, tool calling built-in |
| API Gateway WebSocket + Output Chunks Queue + connection routing | **HTTP streaming (SSE)** from the app, optional **Azure SignalR** | Foundry/AOAI stream tokens natively; drop the queue-and-route machinery |
| 8 Global + 8 Standard AOAI round-robin in app code | **AOAI Global Standard deployment** + **APIM load balancing / model router** | Capacity & failover handled by the platform, not app logic |
| Redis + PostgreSQL (chat_history, chat_control) | **Azure Cosmos DB** (+ optional Azure Cache for Redis) | Multi-region writes, low latency, one store for sessions/history |
| AWS Parameter Store | **Azure App Configuration** + **Key Vault** + **Managed Identity** | Secretless config, no AWS dependency |
| Splunk | **Application Insights / Log Analytics** | Native tracing, token usage, evals |
| EC2 / self-managed compute | **Azure Container Apps** (API) + **Static Web Apps** (React) | Scale-to-zero, KEDA autoscale, fully managed |
