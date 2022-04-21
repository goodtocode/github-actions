# GitHub Actions YAML for Azure Deployments
<sup>github-actions Starter GitHub Actions YAML is a starting point for using GitHub Actions YML files to automate cloud infrastructure, building source, unit-testing source, deploying source and running external integration tests.</sup> <br>

This is a simple GitHub Actions YAML for Azure Deployments [GitHub Actions for Azure](https://docs.microsoft.com/en-us/azure/developer/github/github-actions)

This repository relates to the following activities:
* Deploy [Enterprise-scale Architecture Landing Zones](https://docs.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/#:~:text=Azure%20landing%20zones%20are%20the%20output%20of%20a,as%20a%20service%20or%20platform%20as%20a%20service.)
* Deploy Azure cloud infrastructure
* Building source with dotnet build
* Unit-testing source with dotnet tests
* Deploying source to cloud infrastructure
* And running external integration tests

#### /pipelines folder (YAML)
Path | Item | Contents
--- | --- | ---
pipelines | - | Contains all scripts, steps, variables and main-pipeline files
pipelines | COMPANY-rg-PRODUCT-infrastructure.yml | Main-pipeline file to deploy cloud landing zone, and infrastructure
pipelines | COMPANY-rg-PRODUCT-src.yml | Main-pipeline file to build/test/deply src, unit tests and integration tests

#### /steps folder (YAML)
Path | Item | Contents
--- | --- | ---
pipelines/steps | - | GitHub Actions step templates.
pipelines/steps | func-build-steps.yml | Azure Functions source code build, and package
pipelines/steps | func-deploy-steps.yml |  Azure Functions source code deploy to cloud infrastructure
pipelines/steps | xxx-infrastructure-steps.yml | Azure ESA infrastructure deploy
pipelines/steps | integration-test-steps.yml | Runs external integration tests against src
pipelines/steps | logic-infrastructure-steps.yml | Azure Logic Apps deploy to cloud infrastructure
pipelines/steps | landingzone-infrastructure-steps.yml | Azure ESA Landing Zone deploy
pipelines/steps | nuget-deploy-external-steps.yml | NuGet.org package (.nupkg) deploy
pipelines/steps | nuget-deploy-internal-steps.yml | Private NuGet Feed (.nupkg) deploy
pipelines/steps | dotnet-build-steps.yml | Source code (/src) build with dotnet build
pipelines/steps | dotnet-test-steps.yml |  Source code (/src) unit-test with dotnet test

#### /pipeline/variables (YAML)
Path | Item | Contents
--- | --- | ---
pipelines/variables | - | Variables (non-secret only) for the Azure landing zone, Azure infrastructure and NuGet packages.
pipelines/variables | common.yml | Common variables to all pipelines
pipelines/variables | development.yml | Development environment-specific variables
pipelines/variables | production.yml | Production environment-specific variables

#### /scripts folder (PowerShell)
Path | Item | Contents
--- | --- | ---
pipelines/scripts | - | Contains GitHub Actions YAML files, Windows PowerShell scripts, and variables to support GitHub Actions YAML Pipelines.
pipelines/scripts | System.psm1 | Powershell helpers for system-level functions
pipelines/scripts | Set-Version.ps1 | Sets version per MAJOR.MINOR.REVISION.BUILD methodology
pipelines/scripts | Get-AzureAd.ps1 | Manual script for getting Azure AD information
pipelines/scripts | New-SelfSignedCert.ps1 | Manual script for generating a self-signed certificate

#### Azure Services used in these repositories
Azure Service | Purpose
:---------------------:| --- 
[Azure Cosmos DB](https://azure.microsoft.com/en-us/services/cosmos-db/)| NoSQL database where original content as well as processing results are stored.
[Azure Functions](https://azure.microsoft.com/en-us/try/app-service/)|Code blocks that analyze the documents stored in the Azure Cosmos DB.
[Azure Service Bus](https://azure.microsoft.com/en-us/services/service-bus/)|Service bus queues are used as triggers for durable Azure Functions.
[Azure Storage](https://azure.microsoft.com/en-us/services/storage/)|Holds images from articles and hosts the code for the Azure Functions.

> <b> Note </b> This design uses the service collection extensions, dependency inversion, queue notification, and serverless patterns for simplicity. While these are useful patterns, this is not the only pattern that can be used to accomplish this data flow.
>
> [Azure Service Bus Topics](https://docs.microsoft.com/en-us/azure/service-bus-messaging/service-bus-dotnet-how-to-use-topics-subscriptions) could be used which would allow processing different parts of the article in a parallel as opposed to the serial processing done in this example. Topics would be useful if article inspection processing time is critical.  A comparison between Azure Service Bus Queues and Azure Service Bus Topics can be found [here](https://docs.microsoft.com/en-us/azure/service-bus-messaging/service-bus-dotnet-how-to-use-topics-subscriptions).
>
>Azure functions could also be implemented in an [Azure Logic App](https://azure.microsoft.com/en-us/services/logic-apps/).  However, with parallel processing the user would have to implement record-level locking such as [Redlock](https://redis.io/topics/distlock) until Cosmos DB supports [partial document updates](https://feedback.azure.com/forums/263030-azure-cosmos-db/suggestions/6693091-be-able-to-do-partial-updates-on-document). 
>
>A comparison between durable functions and Logic apps can be found [here](https://docs.microsoft.com/en-us/azure/azure-functions/functions-compare-logic-apps-ms-flow-webjobs).
