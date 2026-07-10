# MCP servers

Stout configures three MCP servers in `.mcp.json` (repo root). Claude Code prompts
you to approve each on first use. All are opt-in; **none stores a secret in the
repo**.

## `azure` — Azure MCP
- **What:** query/manage Azure resources — create & inspect Application Insights,
  fetch connection strings, and run **KQL** to verify telemetry actually landed
  (requests / dependencies / customMetrics / customEvents). Powers end-to-end
  verification of Stout.
- **Runs:** `npx -y @azure/mcp@latest server start` (stdio).
- **Auth:** your Azure CLI login (`az login`) / DefaultAzureCredential — no secret
  in config.

## `microsoft-docs` — Microsoft Learn Docs MCP
- **What:** authoritative Microsoft/Azure documentation on tap (Azure Monitor,
  Breeze ingestion, QuickPulse/Live Metrics, OTLP-ingestion status).
- **Endpoint:** `https://learn.microsoft.com/api/mcp` (remote HTTP) — public,
  no auth.

## `github` — GitHub MCP (optional)
- **What:** richer PR / issue / Actions integration than the `gh` CLI.
- **Endpoint:** `https://api.githubcopilot.com/mcp/` (remote HTTP).
- **Auth:** **OAuth with your GitHub identity** — no PAT. On first use, run `/mcp`
  in Claude Code and authenticate; it opens a browser login and stores a scoped,
  revocable token. Low priority — `gh` already covers most GitHub tasks.

> Security: per the project's prime directive, no secrets live in committed files —
> `azure` uses your `az login`, `github` uses OAuth (browser login), and
> `microsoft-docs` needs no auth. `.claude/settings.local.json` (which may record
> per-user MCP tokens/approvals) is gitignored.
