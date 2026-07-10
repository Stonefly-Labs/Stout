---
name: appinsights-local-setup
description: Procedure to provision an Application Insights resource and obtain its connection string for Stout local dev and testing via the Azure CLI (`az monitor app-insights component create` / `show`), export it as an environment variable for the test harness, and handle it as a secret (never commit it). Use this when asked to "set up App Insights", "create a test/dev App Insights resource", "get a connection string for testing", "provision Application Insights", or as the prerequisite for the real-ingestion path of `verify-telemetry`.
---
# Application Insights — Local Dev/Test Setup

Provision a real Application Insights resource so Stout can send telemetry against
it (the Approach B / real-ingestion path of `verify-telemetry`). The connection
string it produces is a **secret** — treat it with the prime directive's rigor.

## Prereqs

- Azure CLI installed and logged in: `az login`.
- The Application Insights extension:
  ```sh
  az extension add --name application-insights 2>/dev/null || \
    az extension update --name application-insights
  ```
- A subscription selected: `az account set --subscription "<sub-id-or-name>"`.

## 1. Create a resource group (if needed)

```sh
az group create --name stout-dev-rg --location eastus
```

## 2. Create the Application Insights component

Workspace-based is the current default; a Log Analytics workspace backs it. Either
let Azure create/associate a default workspace, or pass one explicitly.

```sh
az monitor app-insights component create \
  --app stout-dev-ai \
  --location eastus \
  --resource-group stout-dev-rg \
  --application-type other \
  --kind other
```

(`--application-type other` / `--kind other` suit a server-side library rather than
a web/mobile app. Add `--workspace <workspace-resource-id>` to bind a specific Log
Analytics workspace.)

## 3. Read the connection string and app id

```sh
# Connection string (has InstrumentationKey, IngestionEndpoint, LiveEndpoint) — SECRET
az monitor app-insights component show \
  --app stout-dev-ai \
  --resource-group stout-dev-rg \
  --query connectionString -o tsv

# App ID (a GUID) — needed to run KQL via `az monitor app-insights query`
az monitor app-insights component show \
  --app stout-dev-ai \
  --resource-group stout-dev-rg \
  --query appId -o tsv
```

The connection string looks like (see `breeze-schema` §3):

```
InstrumentationKey=<guid>;IngestionEndpoint=https://<region>.in.applicationinsights.azure.com/;LiveEndpoint=https://<region>.livediagnostics.monitor.azure.com/
```

## 4. Export for the test harness

Export directly from the CLI so the secret never lands in a file or shell history
literally:

```sh
export STOUT_CONNECTION_STRING="$(az monitor app-insights component show \
  --app stout-dev-ai --resource-group stout-dev-rg --query connectionString -o tsv)"

export STOUT_APPINSIGHTS_APP_ID="$(az monitor app-insights component show \
  --app stout-dev-ai --resource-group stout-dev-rg --query appId -o tsv)"
```

`verify-telemetry` (Approach B) reads `STOUT_CONNECTION_STRING` (to send) and
`STOUT_APPINSIGHTS_APP_ID` (to query with KQL).

## 5. Security (non-negotiable)

- The connection string / `InstrumentationKey` is a **secret**. NEVER commit it,
  NEVER paste it into code, config, a test fixture, a log, or an error message.
- Keep it out of the repo: pass it via env var only. Do not put it in tracked
  files; `.claude/settings.local.json` is gitignored but is still not the place for
  it — prefer the shell env or a local, gitignored `.env` you never stage.
- Do not print it. When echoing config for debugging, redact everything after
  `InstrumentationKey=`.
- Scope it: a throwaway dev resource in a dev resource group, deletable at will.

## 6. Teardown

```sh
az monitor app-insights component delete --app stout-dev-ai --resource-group stout-dev-rg
# or nuke the whole group:
az group delete --name stout-dev-rg --yes --no-wait
```
