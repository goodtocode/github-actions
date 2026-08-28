# AI Agent Operating Guide

## Purpose
Use this guide with `.github/copilot-instructions.md` when making changes in a Microsoft .NET repository. Agents should make the smallest complete change, respect the architecture already present, and leave the repository buildable and testable.

## Reading Order
1. `.github/copilot-instructions.md`
2. `docs/governance/architecture.md`
3. `docs/governance/coding-standards.md`
4. `docs/governance/development-workflow.md`
5. `docs/governance/sprint-0-basic-overview.md`
6. `docs/governance/sprint-0-basic-tools.md`
7. `docs/governance/sprint-0-step-1-ontology.md`
8. `docs/governance/sprint-0-step-2-event-storming.md`
9. `docs/product/sprint-0/overview.md`
10. `docs/product/sprint-0/ontology.md`
11. `docs/product/sprint-0/user-flows.md`
12. `docs/product/features/<feature>.md`

## Agent Workflow
1. Understand architecture boundaries and allowed dependencies.
2. Understand coding and testing standards.
3. Confirm Sprint 0 scope and timebox intent before implementation.
4. Use ontology to stabilize canonical language and definitions.
5. Use event storming outputs to model behavior, commands, actors, and policies.
6. Use user flows and feature requirements to implement the smallest vertical slice.
7. Implement across Domain, Application, Infrastructure, and Presentation as needed.
8. Create or update automated tests.
9. Validate build, behavior, and Definition of Done.

## Agent Constraints
AI agents must never:
- Violate architecture boundaries.
- Bypass coding standards.
- Duplicate business rules across layers.
- Add undocumented dependencies.
- Start behavioral modeling when ontology terms are unresolved.

## Delivery Expectations
Every change should:
- Follow local naming, formatting, nullable, analyzer, and API conventions.
- Include appropriate automated tests or explain a genuine test limitation.
- Preserve backwards compatibility unless a breaking change is intentional and documented.
- Update relevant README or operational documentation.
- Pass the most relevant build, test, lint, format, and infrastructure validation available.

Prefer typed contracts, centralized error handling, secure configuration, and explicit dependency injection. Treat generated clients and migrations according to the repository's established generation and deployment process.
