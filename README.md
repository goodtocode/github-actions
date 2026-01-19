# GitHub Actions YAML for Azure Deployments
<sup>This repo is a starting point for using GitHub Actions YAML files to automate cloud infrastructure, building source, unit-testing source, deploying source and running external integration tests.</sup> <br>

This is a simple GitHub Actions YAML for Azure Deployments [GitHub Actions for Azure](https://docs.microsoft.com/en-us/azure/developer/github/github-actions)

This repository relates to the following activities:
* Deploy [Enterprise-scale Architecture Landing Zones](https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/#:~:text=Azure%20landing%20zones%20are%20the%20output%20of%20a,as%20a%20service%20or%20platform%20as%20a%20service.)
* Deploy Azure cloud infrastructure
* Building source with dotnet build
* Unit-testing source with dotnet tests
* Deploying source to cloud infrastructure
* And running external integration tests

## Repo Contents

#### /workflows folder (YAML)
Path | Item | Contents
--- | --- | ---
workflows | - | Contains all scripts, steps, variables and main-pipeline files
workflows | COMPANY-rg-PRODUCT-infrastructure.yml | Main-pipeline file to deploy cloud landing zone, and infrastructure
workflows | COMPANY-rg-PRODUCT-src.yml | Main-pipeline file to build/test/deply src, unit tests and integration tests

#### /scripts folder (PowerShell)
Path | Item | Contents
--- | --- | ---
workflows/scripts | - | Contains GitHub Actions YAML files, Windows PowerShell scripts, and variables to support GitHub Actions YAML workflows.
workflows/scripts | System.psm1 | Powershell helpers for system-level functions
workflows/scripts | Set-Version.ps1 | Sets version per MAJOR.MINOR.REVISION.BUILD methodology
workflows/scripts | Get-AzureAd.ps1 | Manual script for getting Azure AD information
workflows/scripts | New-SelfSignedCert.ps1 | Manual script for generating a self-signed certificate

#### Azure Services used in these repositories
Azure Service | Purpose
:---------------------:| --- 
[Azure Cosmos DB](https://azure.microsoft.com/en-us/services/cosmos-db/)| NoSQL database where original content as well as processing results are stored.
[Azure Functions](https://azure.microsoft.com/en-us/try/app-service/)|Code blocks that analyze the documents stored in the Azure Cosmos DB.
[Azure Service Bus](https://azure.microsoft.com/en-us/services/service-bus/)|Service bus queues are used as triggers for durable Azure Functions.
[Azure Storage](https://azure.microsoft.com/en-us/services/storage/)|Holds images from articles and hosts the code for the Azure Functions.

## Creating a new Github Repo

### New GitHub Repository Setup — Checklist

| Step | Checklist Item | Notes / Source |
|------|----------------|----------------|
| 1 | [ ] Create repository (UI or CLI) | Use GitHub UI or CLI. Template repos only copy files, not settings.  |
| 2 | [ ] Set branch protection for main | Configure in UI or via CLI.  |
| 3 | [ ] Enable Code Scanning (CodeQL) | Use Default Setup in UI or add workflow file.  |
| 4 | [ ] Enable Secret Scanning & Push Protection | Enable in Security & analysis settings or via CLI. |
| 5 | [ ] Enable Dependabot alerts & security updates | Enable in Security & analysis settings. Add dependabot.yml for version updates.  |
| 6 | [ ] Create development environment | Add environment secrets, restrict to dev branch if needed. |
| 7 | [ ] Create production environment | Add secrets, required reviewers, restrict to main branch.  |
| 8 | [ ] Confirm CI/workflow files exist | Ensure workflows from template are present.  |
| 9 | [ ] Final checks | Verify CI runs, PR rules, CodeQL, Secret scanning, Dependabot, environments, secrets. |

## New GitHub Repository Setup — Manual/CLI Steps

1. Create the Repository

    1.1 In GitHub UI:

    - New → Repository
    - Choose Public + MIT License (OSS) or Private + No license (closed source)
    - Check Add README
    - Add Visual Studio .gitignore

    1.2 OR via GitHub CLI:

    ```sh
    gh repo create <owner>/<repo> \
      --public \  # or --private
      --description "My library" \
      --add-readme \
      --gitignore "VisualStudio" \
      --license "mit"   # omit for private repos
    ```

    Template repositories only copy files, not settings. 


2. Set Branch Protection for main

    Branch protection rules must be configured per‑repo.

    2.1 In GitHub UI:

    - Go to Settings → Branches → Add rule
    - Pattern: main
    - Enable:
      - Require a pull request before merging
      - Require squash merging only
      - Allow author to self‑approve (uncheck “Require review from Code Owners”)
      - Required status checks (leave empty for now—will populate after CI/CodeQL runs)
      - Require conversation resolution
      - Block force pushes & branch deletion

    2.2 CLI (optional—creates/updates a branch protection rule):

    ```sh
    gh api -X PUT "repos/<owner>/<repo>/branches/main/protection" \
      -f required_status_checks.strict=true \
      -f enforce_admins=true \
      -f required_pull_request_reviews='{"require_code_owner_reviews":false}' \
      -f restrictions='{"users":[],"teams":[],"apps":[]}'
    ```

    The REST API updates/creates branch protection rules.

3. Enable Code Scanning (CodeQL)

    Code scanning via CodeQL can be enabled using Default Setup or a workflow file. Default setup is the fastest.

    Default Setup auto‑configures scanning on pushes, PRs, and weekly.

    CodeQL scanning is available for public repos for free.

    3.1 In GitHub UI:

    - Go to Security → Code security & analysis
    - Under Code scanning, click Set up → Default
    - Click Enable CodeQL

    3.2 If you prefer advanced workflow instead:

    - Add .github/workflows/codeql-analysis.yml (copied from your template or GitHub’s starter)

    No CLI is available to "toggle on" Default Setup yet; it must be done in UI, or you commit an advanced workflow file.

4. Enable Secret Scanning & Push Protection

    Secret Scanning: detects leaked secrets in repos.
    Push Protection: blocks pushes containing secret patterns.

    4.1 In GitHub UI

    - Settings → Security & analysis
    - Enable Secret scanning
    - Enable Push protection

    4.2 CLI (recommended):

    ```sh
    gh api -X PATCH repos/<owner>/<repo> \
      -f security_and_analysis='{    "secret_scanning": {"status":"enabled"},    "secret_scanning_push_protection": {"status":"enabled"}  }'
    ```


5. Enable Dependabot Alerts & Security Updates

    Dependabot alerts are repo/org settings; version updates come from dependabot.yml.
    Alerts & security updates must be manually enabled.
    Security updates auto‑open PRs for known vulnerabilities.

    5.1 GitHub UI

    - Settings → Security & analysis
    - Enable Dependabot alerts
    - Enable Dependabot security updates

    5.2 Add version update file (optional):

    ```yaml
    # .github/dependabot.yml
    version: 2
    updates:
      - package-ecosystem: "nuget"
        directory: "/"
        schedule:
          interval: "weekly"
    ```

6. Create the Development Environment

    GitHub Environments allow scoped secrets & protection rules.
    They must be created manually per repo.

    6.1 In GitHub UI:
    - Settings → Environments → New environment
    - Name: development
    - Add environment secrets (e.g., DEV_API_KEY)
    - (Optional) Restrict to branch dev


7. Create the Production Environment

    Production typically has required reviewers & stricter rules.
    Required reviewers are environment‑level protection rules.

    7.1 In GitHub UI:
    
    - Settings → Environments → New environment
    - Name: production
    - Add environment secrets (e.g., PROD_API_KEY)
    - Add Required reviewers (you for now)
    - Restrict deployments to branch main


8. Confirm CI/Workflows Exist (from template)

    Workflow files do propagate from template repos.

    - .github/workflows/ci.yml
    - .github/workflows/codeql-analysis.yml (if using advanced setup)
    - .github/workflows/promote-dev-to-main.yml (your automation)
    - dependabot.yml if using Dependabot version updates
    - CODEOWNERS (optional)


9. Final Checks
    
    - Push a commit → verify CI runs
    - Open a PR → verify branch protections enforce PR rules
    - Confirm CodeQL ran at least once (Security → Code scanning alerts)
    - Confirm Secret scanning is active (Security → Secret scanning)
    - Confirm Dependabot alerts appear
    - Confirm environments show up in deployment dropdowns
    - Confirm environment secrets resolve in Actions logs