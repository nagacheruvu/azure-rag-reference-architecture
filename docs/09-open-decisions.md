# 9. Open decisions

1. **Real-time token streaming** to the browser (SSE/SignalR) vs single response? Decides
   whether SignalR stays.
2. **API layer:** Azure Container Apps (containers, scale-to-zero) vs App Service (simpler;
   `zdd-appservice` diagrams suggest App Service is in use).
3. **Priority access:** APIM rate-limit tiers (MVP) vs one managed Service Bus (async buffering).
4. **First artifact:** agnostic capability map (dark-theme `.drawio`) vs standards-based
   assessment scorecard vs a single 1-week review plan with daily milestones.

## Current defaults baked into this workspace

| Decision | Default chosen here | Where to change |
|---|---|---|
| Streaming | **SSE** from the API (no SignalR) | [`src/api`](../src/api), [`infra/main.bicep`](../infra/main.bicep) |
| API host | **Container Apps** (Consumption) | [`azure.yaml`](../azure.yaml), `infra/modules/container-app.bicep` |
| Priority access | **APIM rate-limit tiers** (Service Bus not provisioned) | `infra/main.bicep` (`deployServiceBus` param) |
| Chat history store | **Cosmos DB serverless** | `infra/modules/cosmos.bicep` |

These are starting points — flip the parameters in [`infra/main.parameters.json`](../infra/main.parameters.json)
to scale up for load tests or enable multi-region.
