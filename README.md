## GitHub Actions Templates for Azure CI/CD

This repository provides ready-to-use GitHub Actions YAML templates and PowerShell scripts for automating CI/CD pipelines for .NET web APIs, Blazor apps, Bicep-based infrastructure-as-code (IaC), Azure Static Web Apps, and NuGet package publishing.

## Overview

These templates help you:
- Build, test, and deploy .NET web APIs and Blazor applications to Azure
- Deploy Azure infrastructure using Bicep (IaC)
- Build and publish NuGet packages
- Deploy Azure Static Web Apps
- Use best practices for secure, automated, and repeatable deployments

## Repository Structure

### Workflows (`/workflows`)

Workflows are named after the `.azure` templates they deploy: `{platform|workload-<archetype>|package}-{capability}[-{variant}].yml`. Mode, environment and components are variables, not separate files.

| File | Purpose |
|------|---------|
| `workload-digitalproduct-iac.yml` | Deploy a digital product (any mode: standalone, shared, network, zerotrust), development then production |
| `workload-digitalproduct-app.yml` | Build, test and deploy web, API and SQL migrations using Entra or SQL credentials; components switched by `HAS_WEB`, `HAS_API`, `HAS_SQL`, `HAS_E2E`; exact deployment outputs select app/monitoring/database targets |
| `platform-shared-edge-iac.yml` | Phase 2 platform edge (Front Door) in the platform subscription |
| `platform-shared-mgmt-iac.yml` | Phase 2 shared management, development then production |
| `platform-shared-ai-iac.yml` | Azure AI (Foundry or Ollama) in the product's resource group; `AI_VARIANT` picks the template |
| `platform-hub-iac.yml`, `platform-spoke-iac.yml` | Phase 3 and 4 hub and spoke network |
| `package-nuget.yml` | Build, test, and publish NuGet packages |

Consumer repos rename `workload-digitalproduct-*` to the product name, for example `crucible-iac.yml` and `crucible-app.yml`.

### Root Setup

Copy [Initialize-Installation.ps1](Initialize-Installation.ps1) to the consuming product root.
Copy `scripts/` into the consumer's `.github/scripts/` and rename the digital-product workflows
under `.github/workflows/` to the product's `*-iac.yml` and `*-app.yml` names.
From `azure-arm`, copy `bicep/modules`, `bicep/types`, `bicep/templates`, and the selected
`bicep/variables` into matching `.azure/` folders, and `scripts/` into `.azure/scripts/`.
Keep the transitive modules/types/scripts together; copying only the top-level templates is insufficient.

The root launcher delegates to [scripts/setup/Initialize-Product.ps1](scripts/setup/Initialize-Product.ps1).
Local mode reconciles sign-in registrations,
user-secrets and existing local migrations. Cloud Prepare ensures federation/environment/secrets,
then exits so the operator can review/publish and run product IaC. Cloud Complete verifies the named
deployment, adds hosted redirects, refreshes local telemetry and runs Entra SQL user provisioning
as the authorized signed-in administrator. SQL-auth access is provisioned by the pipelines.
Existing client secrets are reused, never silently rotated; missing values are prompted securely.
GitHub environment protections are preserved. Setup performs no commits, pushes or destructive resets.
The setup-selected `SQL_SERVER_AUTHENTICATION` secret selects owned-server creation policy without
allowing conversions, and the explicit administrator-group secret takes precedence over YAML.

```powershell
./Initialize-Installation.ps1 -Mode Local
./Initialize-Installation.ps1 -Mode Cloud -SqlAuthentication SqlAuth
# Review and run the product IaC workflow, then resume:
./Initialize-Installation.ps1 -Mode Cloud -Stage Complete
```

The optional `scripts/setup/Initialize-Development.ps1` retains AFQS's advanced local-only
options for deployment-name overrides, telemetry and an explicit local connection string.
It is copied to `.github/scripts/setup/`; the installation launcher remains the primary entry point.
The installer currently recognizes the Crucible, Compass and AFQS solution layouts. Other layouts
must adapt product/project discovery rather than assuming that copying the launcher alone configures them.

### Digital-product SQL/identity contract

Both workflow files use `IAC_DEPLOYMENT_NAME` (default `workload-digitalproduct`); IaC must successfully deploy that name before app CD. Set the environment variable `AZURE_RESOURCE_GROUP_NAME` to override the example RG naming slots in both workflows. For a web-only deployment, supply `BACKEND_API_BASE_URL` and the external API client ID. PR IaC checks compile offline and do not create resource groups or sign in to Azure.

Set the environment secret `SQL_ENTRA_ADMIN_GROUP_OBJECT_ID` to an existing workload-tenant administrator group. The secret takes precedence over the YAML `env` fallback. Non-secret RG overrides and web-only backend URLs are YAML settings; no GitHub Variables are required. `AZURE_TENANT_ID` comes from the existing OIDC login configuration. Example parameter GUID placeholders are accepted only for compilation; deployment validates non-placeholder administrator IDs before creating resources.

After the Entra-only database exists, an already authorized SQL administrator must run `azure-arm/scripts/sql/Set-AzureSqlManagedIdentityUsers.ps1` once to grant the API UAMI client ID runtime DML and the GitHub OIDC application client ID migration DML/DDL. Repeat bootstrap safely when needed. This does not grant Azure RBAC, create directory objects, or automatically authorize the GitHub principal as SQL administrator.

IaC supports creation-time `EntraOnly` and `SqlAuth` choices. For `SqlAuth`, configure four GitHub
environment secrets: `SQL_ADMIN_USER`, `SQL_ADMIN_PASSWORD`, `SQL_MIGRATION_USER`, and
`SQL_MIGRATION_PASSWORD`. The administrator username overrides `sql.server.administratorLogin`.
Never place a password inside the component configuration. Run IaC, then app CD; both pipelines
automatically ensure database access with `Set-AzureSqlPasswordUsers.ps1`. `Get-WorkloadSqlCreateMode.ps1` uses read-only
lookups to select creation versus ordinary updates. Updates omit creation-only authentication
settings; mode or immutable SQL-login mismatches require operator-managed replacement.
No pipeline converts authentication modes or deletes resources. Referenced servers must already
match `sql.server.authentication` (default `EntraOnly`); the workflow never modifies them.
Verify real SQL-backed operations, sign-in, wrong-identity rejection, least
privilege and redeployment; `/health` is not SQL proof. The migration principal must not be a
member of the administrator group. The deployment owner selects the administrator group in
its own workload tenant; customer installations do not implicitly authorize publisher access.

Both deployment jobs use the same environment concurrency group to prevent overlapping resource/app mutations. This lock does not order workflows: explicitly run changed IaC before app CD, and bootstrap before the first migration. Rebootstrap replacement identities/new databases. Administrator preparation is deliberately not a CI secret or automatic privilege escalation.

`Get-WorkloadDeployment.ps1` requires a successful named deployment and reads explicit app/monitoring/SQL/identity outputs. `Invoke-AzureSqlMigration.ps1` uses the already logged-in Azure CLI identity or an explicit SQL migration credential with SqlServer module 22+. SQL-auth provisioning uses the administrator only to ensure a contained migration user with DML/DDL and a separate runtime user with DML. Runtime passwords are generated cryptographically, stored in the API's `DefaultConnection` App Service connection string, and reused on later deployments. No `SQL_RUNTIME_*` secrets, Key Vault, interactive prompts, or manual SQL user creation are required for this path. Conflicting users, elevated permissions, or unrelated existing connection strings fail closed rather than being silently adopted. Entra app CD uses the explicitly selected API UAMI. Both paths require encrypted, certificate-validated connections.

Migration execution rejects `db_owner` and a principal lacking `db_ddladmin`; product-specific grants require administrator review. External ID Instance/ValidateAuthority settings are retained in both app configurations. Never print configuration responses containing the remaining AI/web secrets.

The app workflow consumes the selected SQL authentication contract and requires an explicit API UAMI client ID when using managed identity. An existing server must already authorize the chosen identities or SQL users and runner connectivity. Adopting an existing database requires a separate owner-approved review. Product-specific migrations may need reviewed additional migration permissions. Normal CD never wipes databases; any cloud reset is a separate explicitly targeted, confirmed operation, never an implicit extension of a local reset.

AI test credentials are process environment variables, not substituted into published appsettings. AI runtime keys and External ID web credentials are deliberately unchanged in this slice; they require separate authentication work. Local clone/debug setup does not acquire managed identities or change LocalDB authentication.

### Maturity roadmap pipelines

Each phase adds to the previous one. Pick the phase that fits and copy only its pipelines. Resource groups follow `{product}-{env}-{region}-{instance}-rg`, set in the naming slots at the top of each workflow.

| Phase | Subscriptions | Pipelines | GitHub environments |
| --- | --- | --- | --- |
| 1. Cloud native startup | 1 | `workload-digitalproduct-iac.yml` (`MODE: standalone`), `workload-digitalproduct-app.yml` | `development` |
| 2. Subscription segmentation | platform, development, production | `platform-shared-edge-iac.yml`, `platform-shared-mgmt-iac.yml`, `workload-digitalproduct-iac.yml` (`MODE: shared`), `workload-digitalproduct-app.yml`, optional `platform-shared-ai-iac.yml` | `platform`, `development`, `production` |
| 3. Enterprise network foundation | same | Phase 2 plus `platform-hub-iac.yml`, `platform-spoke-iac.yml` | same |
| 4. Zero trust private services | same | Phase 3 with the zero-trust templates | same |

Environment pipelines run development first, then production behind the required reviewers of the `production` environment. Create one Azure identity per environment with `scripts/cd/New-Github-Azure-Federation.ps1`.

### Triggers
All workflow YAML files in this repo are designed to:
- **Trigger CI**: On any Pull Request (PR) to any branch (runs build/test/validate only)
- **Trigger CD**: On push to the `main` branch (runs full deployment)

A newer pull request run cancels the superseded one. Pushes to `main` queue instead, so a running deployment is never cancelled.

| Workflow File                        | Purpose                                                                                 | CI Trigger (PR)         | CD Trigger (Push to main) |
|--------------------------------------|-----------------------------------------------------------------------------------------|-------------------------|---------------------------|
| `workload-digitalproduct-app.yml` | Build, test and deploy web, API and SQL migrations                                 | Yes                    | Yes                      |
| `workload-digitalproduct-iac.yml` | Deploy a digital product with Bicep                                                | Yes (what-if)          | Yes                      |
| `package-nuget.yml`          | Build, test, and publish NuGet packages                                                 | Yes                    | Yes                      |

### GitHub to Azure federation

Pipelines log in with OpenID Connect, so no secret is stored. Use one app registration per repository, named `github-<repo>`, and run `scripts/cd/New-Github-Azure-Federation.ps1` once per environment with the same `-PrincipalName`. Each run signs in to that environment's subscription, grants the app Contributor there, and appends a federated credential for that environment to the same app registration. Run it as an administrator, after `gh auth login` (the script asks the repo for its OIDC subject prefix, which is `repo:owner/repo` or the immutable `repo:owner@ownerId/repo@repoId` form depending on the repo).

```powershell
.\New-Github-Azure-Federation.ps1 -TenantId <tenant-guid> -SubscriptionId <platform-subscription-guid> `
  -PrincipalName github-<repo> -Organization <org> -Repository <repo> -Environment platform

.\New-Github-Azure-Federation.ps1 -TenantId <tenant-guid> -SubscriptionId <development-subscription-guid> `
  -PrincipalName github-<repo> -Organization <org> -Repository <repo> -Environment development
```

| Repo | Run | `-Environment` | `-SubscriptionId` | `-PrincipalName` |
| --- | --- | --- | --- | --- |
| platform | 1 | `platform` | platform | `github-platform-azure` |
| platform | 2 | `development` | development | `github-platform-azure` |
| platform | 3 | `production` | production | `github-platform-azure` |
| product | 1 | `development` | development | `github-<product>` |
| product | 2 | `production` | production | `github-<product>` |

- `-Environment` is the GitHub environment name and must exist in the repository. It accepts a list, but each run must use the subscription of its environments. Pipelines that set `environment:` present a subject for that environment, and the script adds one credential named `<PrincipalName>-env-<environment>` per environment. Rerunning is safe.
- Use a different `-PrincipalName` for each repository. Two repositories sharing one app registration would share its credentials and roles.
- `-Organization` can be an organization or a personal account. Rerunning replaces a credential whose subject is wrong. To switch GitHub accounts use `gh auth switch`. The Azure side switches to a saved context for the `-TenantId` and `-SubscriptionId`, or signs in to that tenant.
- The app registration is the same across environments, so `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` are the same value everywhere. `AZURE_SUBSCRIPTION_ID` differs. Because the app has Contributor on every subscription you ran it for, a workflow that can log in as the app could target any of them. Protect `production` with required reviewers and restrict who can edit workflows, or use a separate app registration per environment if you need a hard boundary.
- The script also adds `main` and `pull_request` credentials. Those do not go through environment protection, so remove them if every job sets `environment:`.
- It prints `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` and `AZURE_CLIENT_ID`. Save them as secrets on the matching GitHub environment, not on the repository.

### Scripts (`/scripts`)

Scripts are organized by function:
- `ci/` - Versioning, build, and test helpers (e.g., `Get-Version.ps1`, `Set-Version.ps1`)
- `cd/` - Managed identity and NuGet package management
- `repo/` - GitHub repo and secret automation
- `System.psm1` - Common PowerShell functions

## How to Use

1. **Copy the relevant workflow YAML(s) from `/workflows` into your repo's `.github/workflows/` directory.**
2. **Update placeholder values** (e.g., `COMPANY`, `PRODUCT`, resource names, paths) to match your project.
3. **Add required secrets** to your GitHub repository (Azure credentials, API keys, etc.). See each workflow for required secrets.
4. **(Optional) Customize scripts** in `/scripts` for your environment or extend as needed.
5. **Push changes to trigger the workflows.**

### Example: Deploying a .NET Web API to Azure
- Use `workload-digitalproduct-app.yml` and set `HAS_WEB`, `HAS_API` and `HAS_SQL` for the components you have. Set the same `IAC_DEPLOYMENT_NAME` as the IaC workflow, and `HAS_E2E` to `true` to run an end-to-end test project against the deployed API.
- Ensure your repo contains a `.sln` and project files in the expected structure.
- Configure OIDC identifiers `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, plus YAML `SQL_ENTRA_ADMIN_GROUP_OBJECT_ID` for owned SQL (or an environment secret when YAML is empty). Provision contained database users before app CD; no SQL-password secrets are required.
- The workflow will build, test, publish, and deploy your app to Azure App Service, and (if using SQL) run EF Core migrations.

### Example: Deploying Infrastructure with Bicep
- Use `workload-digitalproduct-iac.yml` and set `MODE`.
- Place your Bicep templates and parameter files in the `.azure/` directory.
- Add Azure credentials as secrets.
- The workflow will create/validate/deploy resource groups and Bicep templates.

### Example: Publishing a NuGet Package
- Use `PRODUCT-nuget.yml`.
- Add your NuGet API key as a secret (`NUGET_API_KEY`).
- The workflow will build, test, pack, and publish your package to NuGet.org.

# Github Actions for Azure IaC and CI/CD

## Setting up GitHub Actions to Deploy to Azure

Follow these steps to configure your environment for GitHub Actions CI/CD and Azure deployment:

**Step 1: Create EEID Web and API App Registrations**

Use the provided PowerShell script to create both the Web and API app registrations in your Entra External ID (EEID) tenant. Replace the placeholders with your actual values:

```powershell
pwsh -File ./.azure/scripts/New-EntraDotnetSolution.ps1 \
	-EntraInstanceUrl "https://<your-tenant-name>.ciamlogin.com" \
	-TenantId "<your-tenant-id>" \
	-WebAppRegistrationName "<web-app-registration-name>" \
	-ApiAppRegistrationName "<api-app-registration-name>" \
	-WebProjectPath "./src/Presentation.Blazor" \
	-ApiProjectPath "./src/Presentation.WebApi" \
	-GenerateSecrets
```

This script will output the required IDs and URIs for your environment.

**Step 2: Set GitHub Environment Secrets**

Set the required secrets in your GitHub repository for the deployment workflows. You can use the provided script, replacing the placeholders with your actual values:

```powershell
$secrets = @{
	API_CLIENT_ID        = "<api-app-client-id>"
	AZURE_CLIENT_ID      = "<azure-client-id>"
	AZURE_OPENAI_APIKEY  = "<azure-openai-api-key>"
	AZURE_OPENAI_ENDPOINT = "<azure-openai-endpoint>"
	AZURE_SUBSCRIPTION_ID= "<azure-subscription-id>"
	AZURE_TENANT_ID      = "<azure-tenant-id>"
	E2E_CLIENT_ID        = "<e2e-app-client-id>"
	E2E_CLIENT_SECRET    = "<e2e-app-client-secret>"
	EEID_INSTANCE        = "<eeid-instance-url>"
	EEID_TENANT_ID       = "<eeid-tenant-id>"
	WEB_CLIENT_ID        = "<web-app-client-id>"
	WEB_CLIENT_SECRET    = "<web-app-client-secret>"
}

$secrets.GetEnumerator() | ForEach-Object {
	./.github/scripts/repo/New-GithubSecret.ps1 \
		-Owner <github-org-or-user> \
		-Repo <repo-name> \
		-Environment <environment-name> \
		-SecretName $_.Key \
		-SecretValue $_.Value
}
```

To upsert one secret across several repos or every repo of an owner (existing values are overwritten), use `-Repo a,b` or `-AllRepos`, add `-Environment development,production` for environment secrets, and preview with `-WhatIf`:

```powershell
./.github/scripts/repo/New-GithubSecret.ps1 -Owner <github-org-or-user> -AllRepos -Environment development,production -SecretName AZURE_OPENAI_APIKEY -SecretValue "<value>" -WhatIf
```

If you are using a hub-and-spoke topology, also set:

```powershell
PLATFORM_SUBSCRIPTION_ID="<platform-subscription-id>"
```

**Step 3: Federate Azure Subscription and GitHub Repo**

Run the following script to federate your Azure subscription with your GitHub repository. Replace the placeholders with your actual values:

```powershell
pwsh -File ./.github/scripts/repo/New-Github-Azure-Federation.ps1 \
	-TenantId "<azure-tenant-id>" \
	-SubscriptionId "<azure-subscription-id>" \
	-PrincipalName "<federated-identity-name>" \
	-Organization "<github-org-or-user>" \
	-Repository "<repo-name>" \
	-Environment "<environment-name>"
```

---

This setup ensures your GitHub Actions workflows can securely deploy to Azure using federated credentials and the required secrets.


# Best Practices & Recommendations
- **Keep secrets secure:** Use GitHub Secrets for all credentials and sensitive values.
- **Branch protection:** Enable branch protection and require PRs for main branch deployments.
- **Code scanning:** Enable CodeQL and secret scanning for security.
- **Environment separation:** Use GitHub Environments for dev/prod and restrict deployments appropriately.
- **Dependabot:** Enable Dependabot for dependency and security updates.
- **Customize as needed:** These templates are a starting point—adapt them for your org/project.

# Additional Resources
- [GitHub Actions for Azure](https://docs.microsoft.com/en-us/azure/developer/github/github-actions)
- [Azure Bicep Documentation](https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)

---
