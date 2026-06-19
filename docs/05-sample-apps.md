# 5. Ready-made sample apps (Contoso Q&A)

The closest ready-made match to the "Ask Maya" UI is Microsoft's official
**"Chat with your own data"** sample accelerators — Contoso-branded Q&A web apps that deploy
with one `azd up`.

## Best fit: `Azure-Samples/azure-search-openai-demo`

Ships with **Contoso Electronics / Northwind Health** sample PDFs and maps almost 1:1 to the
Ask Maya UI:

| Ask Maya feature | Sample equivalent |
|---|---|
| Chatbot UI, "New Question", recent questions | React chat UI with chat-history panel |
| **Summary Mode** | **"Chat"** tab — conversational, LLM synthesizes over retrieved docs |
| **Precise Mode** | **"Ask"** tab + retrieval/prompt settings to force strict grounding |
| Citations / "check against sources" | Inline citations + supporting-content + thought-process |
| Suggested starter questions | Configurable example prompts on landing screen |
| Solr vector DB + embeddings | **Azure AI Search** with integrated vectorization |
| OpenAI via APIM | **Azure OpenAI** (gpt-4o-mini + embeddings), optional APIM |
| chat_history / Redis / Postgres | Optional **Cosmos DB** chat-history feature flag |
| Document ingestion | **Document Intelligence + indexer** pipeline included |
| One template per env | **`azd up`** → Bicep, Container Apps/App Service |

Available in **C#, Java, JavaScript, and Python** — match your stack (current backend is
Java → `Azure-Samples/azure-search-openai-demo-java`).

## Get it running (~15 min)

```bash
azd auth login
azd init -t azure-search-openai-demo   # pulls the repo + sample Contoso/Northwind data
azd up                                  # provisions Search, AOAI, hosting, ingests docs
```

`azd up` deploys infra **and** indexes the bundled sample PDFs. Swap in your own docs via the
`data/` folder and re-run ingestion.

## Other Microsoft options

- **"Chat with your data" Solution Accelerator** (`Azure-Samples/chat-with-your-data-solution-accelerator`)
  — Contoso-branded, more enterprise: admin upload UI, chat history, Speech, more config.
- **AI Foundry portal → "Add your data" → "Deploy as a web app"** — zero-repo smoke test.

## Two features the samples don't include out of the box

1. **5 questions / 500-char limit per thread** → enforce client-side in the React input + a
   server-side guard in the chat endpoint.
2. **Input grayed out under high load** → front the API with **APIM rate-limit/quota policy**;
   on `429` the UI disables the input and shows the "return later" message — the resilient
   replacement for the old queue/wait-time logic.
