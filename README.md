# Microsoft Foundry — MongoDB + Azure AI Samples

A collection of samples and reference architectures for building AI-powered applications with **MongoDB Atlas** and **Microsoft Azure AI Foundry**.


## What's Inside

| Sample | Description | Technologies |
|--------|-------------|--------------|
| [simple-rag-movies](./simple-rag-movies/) | Fully automated, single-script deployment of a Microsoft Foundry agent performing RAG over MongoDB Atlas movie data via MCP tools | Microsoft Foundry, Azure Native MongoDB Atlas, Atlas Vector Search, MongoDB MCP Server, Azure Functions (Flex Consumption), Bicep, PowerShell |

### simple-rag-movies

Build a **Microsoft Foundry agent** that performs **semantic search over MongoDB Atlas** sample movie data — deployed end to end with **one script** (`./scripts/setup-and-deploy.ps1`). The sample includes:

- **Foundry prompt agent** (gpt-5-mini) wired to MCP tools:
  - an **embedding Function** (Flex Consumption) that serves the `semantic_search` MCP endpoint and relays all other calls untouched
  - the **MongoDB MCP Server** on Azure Container Apps — the only component holding the connection string, performing all database operations
- **Full automation** — one command sets up Atlas (cluster, sample data, vector index), provisions Azure (Foundry account, models, Function, Container App), and creates the agent
- **GitHub Codespaces dev container** for a zero-local-install deployment path
- **Infrastructure as Code** — Bicep templates for the MCP Server and embedding Function
- **Sample queries** and **agent instructions** to test semantic search, direct filters, and aggregations

→ Get started here: [simple-rag-movies/README.md](./simple-rag-movies/README.md)

## Repository Structure

```
Microsoft_Foundry/
├── README.md                        # This file — hub overview
├── MSFT Foundry_Architecture.png    # Reference architecture diagram
└── simple-rag-movies/               # Sample: Foundry agent + Atlas Vector Search RAG
    ├── README.md                    # Sample setup guide
    ├── LICENSE                      # Sample license
    ├── sample-queries.md            # Example queries to test the agent
    ├── deploy/                      # Bicep templates + config.example.json
    ├── docs/                        # Architecture doc and agent instructions
    ├── imgs/                        # Sample architecture diagram
    ├── scripts/                     # setup-and-deploy.ps1 + atlas/ and azure/ automation
    ├── src/embedding-function/      # Azure Function (Python) for embeddings
    └── .devcontainer/               # GitHub Codespaces dev container
```

## Security

This repository follows security best practices:

- **No secrets in source control** — `.gitignore` excludes `.env` files, `local.settings.json`, certificates, and other credential files
- **Secrets are passed as parameters** — all deployment templates use `@secure()` parameters (Bicep) / `securestring` (ARM), and deployment scripts prompt for credentials at runtime
- **Configuration via environment variables** — sample code reads credentials from environment variables, never hardcoded
- Template files (e.g., `local.settings.json.template`) contain only placeholders — copy them and fill in your own values locally

> If you ever accidentally commit a secret, rotate it immediately and remove it from git history.

## Prerequisites

Most samples in this hub require:

- An [Azure subscription](https://azure.microsoft.com/free/)
- An [Azure AI Foundry project](https://ai.azure.com)
- A [MongoDB Atlas](https://www.mongodb.com/cloud/atlas) cluster (M0 free tier works)
- [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli)

Each sample's README lists its specific prerequisites and setup steps.

## Contributing

New samples should follow the existing structure: a dedicated folder with its own `README.md`, IaC under `deploy/`, documentation under `docs/`, and source under `src/`. Never commit credentials — see the Security section above.
