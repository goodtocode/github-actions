# Copilot Instructions for Microsoft .NET Repositories

## Scope
This repository is a reusable GitHub Actions template for Microsoft .NET applications and libraries. Individual projects may include ASP.NET Core Web API, Blazor, Azure Functions, Azure Bicep, SQL Server, Microsoft identity, Microsoft Agent Framework, and NuGet packages. Apply only the guidance relevant to projects that actually exist.

## Dependency Policy
- Prefer the .NET Base Class Library, ASP.NET Core, Microsoft.Extensions, Entity Framework Core, Azure SDKs, and other Microsoft-maintained packages.
- Goodtocode packages are allowed when they are part of the repository's established platform.
- Do not add non-Microsoft dependencies without explicit justification, approval, and documentation in the project or README.
- Keep domain projects free of infrastructure dependencies where the architecture supports that boundary.
- Centrally manage package versions, review transitive dependencies, and remove unused packages.

## Architecture
- Preserve the architecture already defined by the solution. Do not invent a layer structure when the repository has one.
- A common arrangement is Presentation -> Application -> Domain, with Infrastructure depending on Application/Domain as needed. Domain code should not depend on presentation, persistence, Azure, or UI frameworks.
- Keep business rules in domain/application services, persistence in infrastructure, and transport concerns in API or Functions adapters.
- Use dependency injection and interfaces at genuine boundaries; avoid abstractions that only rename a direct call.

## .NET and C#
- Follow the SDK and language version declared by the repository; use the latest supported version only when upgrading is intentional.
- Enable nullable reference types and analyzers where the solution does so. Treat warnings as errors when configured.
- Use async APIs end to end for I/O and accept `CancellationToken` on application and infrastructure operations where practical.
- Follow local naming and formatting. Generally use PascalCase for public symbols, `_camelCase` for private fields, and camelCase for locals.
- Use Microsoft logging, options binding, DataAnnotations or the repository's established validation mechanism, and centralized exception handling.
- Add XML documentation for public APIs when required by project settings.

## ASP.NET Core Web API
- Follow the existing endpoint style: controllers or Minimal APIs. Do not introduce a second style casually.
- Use resource-oriented, plural, kebab-case routes where that is the established convention.
- Validate input at the boundary, enforce authorization before data access, and return consistent typed results.
- Do not expose secrets, internal identifiers, stack traces, or database exceptions in responses.
- Keep OpenAPI and generated clients synchronized with contract changes.

## Blazor
- Prefer the Microsoft Blazor and Fluent UI components already used by the application.
- Keep UI state and rendering concerns in components; put business behavior behind injected application/API services.
- Avoid JavaScript interop when a .NET or component-based solution exists. Do not add third-party UI libraries without approval.
- Preserve accessible labels, keyboard navigation, responsive layouts, loading states, empty states, and error states.

## Azure Functions and Azure
- Follow the hosting and trigger models already used by the Function App. Keep functions thin and delegate business logic to application services.
- Use managed identity, workload identity federation, Key Vault references, or GitHub/Azure secret stores instead of hard-coded credentials.
- Keep deployment configuration in Bicep or the repository's established IaC system. Validate templates and parameters before deployment.
- GitHub Actions must use least-privilege `permissions`, environment protection for deployments, and action versions consistent with the repository.
- Never add a test-only authentication bypass or production endpoint.

## SQL Server and EF Core
- Use EF Core and parameterized commands. Never concatenate user input into SQL.
- Keep migrations explicit and reviewable; do not apply migrations automatically at application startup unless the repository explicitly requires it.
- Add indexes and constraints for real query and integrity requirements. Consider tenant and owner filters for every protected read and write.
- Use transactions for multi-step invariants and avoid accidental tracking or unbounded queries.

## Security and Data Handling
- Treat all external input, secrets, tokens, uploaded files, and AI output as untrusted.
- Enforce authentication, authorization, tenant isolation, and ownership at the server boundary and in data queries.
- Log useful operational context without credentials, tokens, personal data, or full request bodies.
- Do not commit secrets, local settings, generated credentials, or environment-specific production values.

## Testing and Validation
- Add focused unit tests for domain/application behavior and integration tests for database, API, Function, and Azure boundaries as appropriate.
- End-to-end tests should exercise supported public interfaces and realistic data; do not bypass the API or replace the system under test with fakes.
- Test success, validation, authorization, not-found, concurrency, and dependency-failure paths relevant to the change.
- Prefer the narrowest focused test first, then run `dotnet build` and the repository's documented test, format, and IaC checks.

## Documentation and Changes
- Keep README, configuration examples, API contracts, migrations, and deployment instructions aligned with implementation.
- Make small, reviewable changes. Do not reformat unrelated files or rewrite generated artifacts manually.
- Before finishing, inspect the diff for accidental dependency, permission, secret, route, schema, and environment changes.
