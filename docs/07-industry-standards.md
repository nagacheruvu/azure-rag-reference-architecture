# 7. Industry standards & reference frameworks (keep it agnostic)

## 7.1 Capability-modeling standards

| Standard | What it gives you |
|---|---|
| **TOGAF 10 — Capability-Based Planning** | Model business/technical capabilities independent of products — the "agnostic view" |
| **Business Architecture Guild — BIZBOK** | Business Capability Maps; anonymize/compare at capability level |
| **ArchiMate 3.2** | Notation to draw capability → application → technology layers |
| **IT4IT (Open Group)** | Reference architecture for value streams (build/run/secure) around an AI product |

## 7.2 AI / RAG reference-architecture standards

| Standard | Alignment |
|---|---|
| **Azure Well-Architected Framework — AI Workloads** | 5 pillars (Reliability, Security, Cost Optimization, Operational Excellence, Performance Efficiency) → scalability/cost/resiliency goals |
| **Microsoft Cloud Adoption Framework (CAF) — AI scenarios** | Landing-zone + multi-region/multi-environment governance |
| **Azure Architecture Center — "Baseline OpenAI end-to-end chat"** | Canonical managed-services RAG reference |
| **OpenAPI 3.1 + AsyncAPI** | Standardize API/streaming contracts (SSE/WebSocket) agnostically |

## 7.3 Responsible-AI & risk standards

| Standard | Why it belongs in the review |
|---|---|
| **NIST AI Risk Management Framework (AI RMF 1.0)** | Neutral standard for governing an AI system — Map/Measure/Manage/Govern |
| **ISO/IEC 42001:2023** | AI Management System (the "ISO 27001 for AI") — certifiable, vendor-neutral |
| **ISO/IEC 23894** | AI-specific risk management guidance |
| **Microsoft Responsible AI Standard v2** | Concrete grounding for agnostic NIST/ISO requirements |
| **OWASP Top 10 for LLM Applications (2025)** | Prompt injection, data leakage — assesses the RAG pipeline |
| **MITRE ATLAS** | Adversarial threat modeling for the AI system |

## 7.4 Security, data & operations standards (cross-cutting)

| Standard | Capability covered |
|---|---|
| **ISO/IEC 27001 / 27017 / 27018** | Infosec, cloud security, PII in cloud |
| **SOC 2 Type II** | Trust criteria for a SaaS-style internal product |
| **NIST SP 800-207 — Zero Trust** | Private-network / managed-identity posture |
| **DAMA-DMBOK** | Data governance for document/knowledge-base ingestion |
| **CIS Benchmarks** | Hardening baseline for the managed services |
| **SRE / Google SRE workbook (de-facto)** | SLO/SLI definitions for the resiliency outcome |
