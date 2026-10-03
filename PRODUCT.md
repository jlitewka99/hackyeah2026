# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

The frontend serves three equally important audiences. No audience takes priority over the others, and these audience descriptions do not prescribe an authentication or permissions model.

- **Security teams** need to understand active controls, investigate blocked or redacted interactions, connect enforcement decisions to the applicable policy, and inspect and export audit evidence.
- **Developers and platform engineers** need to understand restrictions on their AI integrations, diagnose why an interaction was allowed, blocked, or redacted, and observe the effects of configuration changes.
- **Management** needs to understand the overall security posture, policy violations, budget consumption, costs, and resource usage without having to investigate each individual interaction.

Hackathon judges are an additional evaluation audience. They may run the system and its tests, submit unprepared prompts, change configuration or feeds, and inspect the resulting behavior.

## Product Purpose

Provide the interactive frontend for AI Control Layer: a system that secures and governs interactions involving AI agents, MCP services, LLMs, and APIs while preserving developer productivity.

The interface should help users answer three questions: how are AI interactions being protected, which events require attention, and how much of the available budget and resources is being consumed?

Frontend success means that users can understand the active protection, inspect the actual results of governed interactions, and use security and resource evidence to perform their respective jobs. A dashboard's appearance alone is not evidence that the underlying controls work.

## Positioning

The product combines deterministic, non-AI controls with semantic, AI-based controls under a centralized policy source. Its frontend makes that enforcement and resource governance observable and understandable across the three audiences.

The defining context is governed AI interaction: the relationship between an interaction, the controls applied to it, its enforcement outcome, and its resource consumption. Do not imply that every agent protocol, model, threat, or deployment environment is already supported.

## Operating Context

This is an existing Phoenix web project with LiveView, HEEx, and Tailwind available. Future frontend implementation follows the repository's `AGENTS.md` conventions. The public root currently serves the Phoenix starter page; the product dashboard and domain workflows have not been implemented in that surface.

The evaluation setting is a running hackathon demonstration, not just a presentation of static screens. Judges may submit their own prompts, change rules or thresholds, remove controls, modify feeds, and inspect the system's reaction. The frontend should expose actual outcomes and make the effects of active configuration observable. The brief does not mandate a particular reload mechanism or require all evaluation actions to originate in the UI.

The wider system deliverables include a functional control layer, documented sample policies with configurable strictness and budget rules, a simple interactive dashboard, and an executable test suite. The brief also asks for a simple architecture diagram and performance telemetry. These provide context for the frontend; this record does not define their backend implementation.

The team must be able to demonstrate the solution on its own setup. The organizer does not provide datasets, proprietary APIs, paid subscriptions, or specific hardware. This is not a prohibition on resources the team already has.

## Capabilities and Constraints

### Intended frontend capabilities

The following describe required product information and confirmed user needs, not functionality already shipped:

- Present active controls and their deterministic or semantic nature, relevant policy settings and sensitivity thresholds, and allowed models.
- Expose enforcement outcomes using the terms `allow`, `block`, and `redact`; distinguish blocking an interaction from removing sensitive content. These are product terms, not a prescribed API enum.
- Support understanding and investigation of threats and policy violations, including the connection between a decision and its applicable control or policy.
- Provide an understandable view of overall security posture, blocked interactions, and budget usage, with real-time reporting where required by the brief. The brief does not define a numerical security-posture score.
- Present supported financial and resource measurements with clear units, limits, and measurement context. Token usage, compute time, resource access, and financial cost are relevant examples; their exact accounting dimensions remain implementation decisions.
- Make security audit evidence inspectable and exportable so security teams can analyze threats, violations, and usage. Export formats and retention rules are not established.
- Make available performance telemetry understandable for evaluation without inventing latency targets, detection rates, or benchmark results.

The brief describes input and output risks, including prompt injection, exposure of personal data or secrets, unauthorized access, runaway agent execution, and historical exploits. These examples guide the content the frontend may need to explain; they do not establish that every listed detector exists or that protection is comprehensive.

The automated suite must exercise allowed and blocked or redacted cases for implemented controls, including budget limits and exploit mitigation. Displaying test results or running tests from the frontend is not established as a requirement.

### Open decisions

- Whether policies are editable in the UI. Centralized configuration is required, but an on-screen policy editor is not specified.
- Backend architecture, integration form, policy format, selected models, supported integrations, and the concrete control catalog.
- Frontend data contracts, audit export format, budget accounting rules, configuration activation mechanism, and deployment environment.
- Screen structure, navigation, layout, visual identity, typography, and colors. These belong to subsequent frontend design work.

## Brand Commitments

Documentation and the future interface are in English. Use consistent technical terminology for controls, policies, enforcement decisions, threats, budgets, and audit evidence.

AI Control Layer is the task name used for product context; the repository application is named AiControl. A separate commercial name and visual identity have not been selected. The Goldman Sachs partner-task context does not establish a requirement to reproduce its branding.

## Evidence on Hand

- [CRIETRIA AI Control Layer.pdf](<Partner Task [Goldman Sachs] - AI Control Layer/CRIETRIA AI Control Layer.pdf>): the primary brief. Pages 1-2 establish the problem and hybrid control mechanism; page 3 specifies the dashboard, policies, reporting, and tests; page 4 describes evaluation and available resources.
- [RULES AI Control Layer.pdf](<Partner Task [Goldman Sachs] - AI Control Layer/RULES AI Control Layer.pdf>): competition and submission context. This document does not define a visual style or frontend layout.
- Existing Phoenix source and project configuration establish the frontend's implementation environment and starter state. They are not evidence of implemented protection or product reporting.

The PDFs disagree on two scoring weights: the brief assigns 15% to self-testing and 15% to practical implementability and scalability, while the rules assign 20% and 10%, respectively. Both assign 30% to guardrail robustness, 20% to architecture and performance, and 20% to security reporting. Preserve the discrepancy rather than silently choosing a version.

No verified product performance measurements, detection results, customer evidence, or production usage metrics are established by these sources. Any future demonstration fixtures must be identifiable as demonstration data, and requirements must remain distinct from implemented capabilities.

## Product Principles

1. **Explain decisions.** Make it possible to understand an enforcement outcome and relate it to the relevant control or policy, using evidence the system actually provides.
2. **Make limits meaningful.** Show financial and resource usage with explicit units, applicable limits, and measurement context; do not present different dimensions as interchangeable.
3. **Represent evidence honestly.** Distinguish actual activity, demonstration data, unavailable measurements, and intended capabilities. Avoid invented posture scores, coverage claims, or performance results.
4. **Support all three audiences.** Make security investigation, developer diagnosis, and management reporting useful without making one audience's needs the default for everyone.
5. **Make changes observable.** Help users connect active configuration and governed interactions to their actual effects, including allowed, blocked, and redacted outcomes.
