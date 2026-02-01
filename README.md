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

| File | Purpose |
|------|---------|
| COMPANY-PRODUCT-api.yml | CI/CD for .NET Web API (build, test, deploy to Azure App Service) |
| COMPANY-PRODUCT-api-sql.yml | CI/CD for .NET Web API with Azure SQL (includes DB migration) |
| COMPANY-PRODUCT-iac.yml | Deploy Azure infrastructure using Bicep templates |
| COMPANY-PRODUCT-stapp-ci-cd.yml | CI/CD for Azure Static Web Apps (Blazor, SPA, etc.) |
| COMPANY-PRODUCT-nuget.yml | Build, test, and publish NuGet packages |

### Triggers
All workflow YAML files in this repo are designed to:
- **Trigger CI**: On any Pull Request (PR) to any branch (runs build/test/validate only)
- **Trigger CD**: On push to the `main` branch (runs full deployment)

| Workflow File                        | Purpose                                                                                 | CI Trigger (PR)         | CD Trigger (Push to main) |
|--------------------------------------|-----------------------------------------------------------------------------------------|-------------------------|---------------------------|
| `COMPANY-PRODUCT-api.yml`            | CI/CD for .NET Web API (build, test, deploy to Azure App Service)                       | Yes                    | Yes                      |
| `COMPANY-PRODUCT-api-sql.yml`        | CI/CD for .NET Web API with Azure SQL (includes DB migration)                           | Yes                    | Yes                      |
| `COMPANY-PRODUCT-iac.yml`            | Deploy Azure infrastructure using Bicep templates                                       | Yes                    | Yes                      |
| `COMPANY-PRODUCT-stapp-ci-cd.yml`    | CI/CD for Azure Static Web Apps (Blazor, SPA, etc.)                                     | Yes                    | Yes                      |
| `COMPANY-PRODUCT-nuget.yml`          | Build, test, and publish NuGet packages                                                 | Yes                    | Yes                      |

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
- Use `COMPANY-PRODUCT-api.yml` or `COMPANY-PRODUCT-api-sql.yml` for CI/CD.
- Ensure your repo contains a `.sln` and project files in the expected structure.
- Add secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, and (for SQL) `SQL_ADMIN_USER`, `SQL_ADMIN_PASSWORD`.
- The workflow will build, test, publish, and deploy your app to Azure App Service, and (if using SQL) run EF Core migrations.

### Example: Deploying Infrastructure with Bicep
- Use `COMPANY-PRODUCT-iac.yml`.
- Place your Bicep templates and parameter files in the `.azure/` directory.
- Add Azure credentials as secrets.
- The workflow will create/validate/deploy resource groups and Bicep templates.

### Example: Publishing a NuGet Package
- Use `COMPANY-PRODUCT-nuget.yml`.
- Add your NuGet API key as a secret (`NUGET_API_KEY`).
- The workflow will build, test, pack, and publish your package to NuGet.org.

# Github Actions for Azure IaC and CI/CD

## Setting up GitHub Actions to Deploy to Azure

Follow these steps to configure your environment for GitHub Actions CI/CD and Azure deployment:

**Step 1: Create EEID Web and API App Registrations**

Use the provided PowerShell script to create both the Web and API app registrations in your Entra External ID (EEID) tenant. Replace the placeholders with your actual values:

```powershell
pwsh -File ./.azure/scripts/entra/New-EntraAppRegistrations.ps1 \
	-EntraInstanceUrl "https://<your-tenant-name>.ciamlogin.com" \
	-TenantId "<your-tenant-id>" \
	-WebAppRegistrationName "<web-app-registration-name>" \
	-ApiAppRegistrationName "<api-app-registration-name>" \
	-WebProjectPath "./src/Presentation.Blazor" \
	-ApiProjectPath "./src/Presentation.WebApi"
```

This script will output the required IDs and URIs for your environment.

**Step 2: Set GitHub Environment Secrets**

Set the required secrets in your GitHub repository for the deployment workflows. You can use the provided script, replacing the placeholders with your actual values:

```powershell
$secrets = @{
	API_CLIENT_ID        = "<api-app-client-id>"
	AZURE_CLIENT_ID      = "<azure-client-id>"
	AZURE_SUBSCRIPTION_ID= "<azure-subscription-id>"
	AZURE_TENANT_ID      = "<azure-tenant-id>"
	EEID_TENANT_ID       = "<eeid-tenant-id>"
	OPENAI_APIKEY        = "<openai-api-key>"
	SQL_ADMIN_PASSWORD   = "<sql-admin-password>"
	SQL_ADMIN_USER       = "<sql-admin-user>"
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
