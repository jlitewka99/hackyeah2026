# AI Control Layer - Complete System Requirements

This document consolidates the system requirements, deliverables, validation approach, and competition constraints for the Goldman Sachs partner task, **AI Control Layer**. It is intended for the team designing, implementing, testing, and presenting the solution.

It describes the requested system, not the implementation status of this repository. Requirements come from the two supplied PDFs. Examples and suggested verification methods are identified separately so they do not become additional organizer mandates.

## 1. Sources and requirement language

| Reference | Source | Relevant contents |
| --- | --- | --- |
| C | [CRIETRIA AI Control Layer.pdf][criteria] | Context and threats: pp. 1-2, section 1. Challenge: p. 2, section 2. Expected outcomes: pp. 2-3, section 3. Formal requirements: p. 3, section 4. Technology: p. 3, section 5. Validation, resources, and scoring: p. 4, sections 6-8. |
| R | [RULES AI Control Layer.pdf][rules] | Submission and timing: p. 1, clause 5. Eligibility, judging, prizes, and scoring: p. 2, clauses 6-12. Post-deadline changes and ownership: p. 3, clauses 13-14. |

Page references use the physical PDF page numbers, starting at 1. The spelling `CRIETRIA` is preserved from the supplied filename. No precedence between the two documents is assumed where they conflict.

The following labels preserve the strength of the source language:

| Label | Meaning |
| --- | --- |
| **Required** | An explicit requirement, formal requirement, or specified deliverable. |
| **Recommended** | Something the source says to consider, think about, or provide using softer wording. |
| **Example** | An illustrative threat, technique, metric, integration, or tool; not independently mandatory. |
| **Evaluation** | A judging criterion or action judges may perform; not an invented numerical acceptance threshold. |
| **Constraint** | A resource, submission, or participation condition stated in the supplied documents. |
| **Suggested verification** | A practical way to demonstrate a requirement, proposed by this specification rather than prescribed verbatim by the organizer. |

Requirement identifiers are stable references for implementation and review. A verification suggestion does not increase the scope of its associated requirement.

## 2. Purpose, users, and scope

The system must provide a flexible control layer that secures and governs interactions with AI systems while preserving developer productivity. Its purpose is to protect data, enforce security policies, govern resource consumption and spending, and address existing and emerging AI threats. [C, p. 1, introduction and section 1; p. 2, section 2][criteria]

### Intended users

- **Developers and application teams:** integrate the control layer into applications and agent workflows without excessive implementation overhead.
- **Security teams:** configure or supply controls, investigate threats and violations, and analyze audit evidence.
- **Management:** understand overall security posture, blocked interactions, resource consumption, and budget usage.
- **Judges:** run tests, submit ad-hoc interactions, change configuration, and inspect the architecture and reporting.

These are audiences, not a mandatory user-role or permission schema. Sources: [C, pp. 1-3, sections 1-4; p. 4, section 6][criteria].

### System boundary

The assessed component is the control layer and its policies, enforcement, reporting, and tests. It may be a gateway, proxy, middleware, SDK wrapper, or another suitable component. There is no prescribed deployment topology. [C, p. 2, sections 2 and 3.1][criteria]

Examples of governed interactions include application-to-agent, agent-to-agent, agent-to-MCP, and agent-to-model communication. The broader context also includes APIs. These examples describe possible integration points; the PDFs do not explicitly require implementations of every protocol or every integration type. [C, p. 1, introduction; p. 2, section 3.1][criteria]

An existing agent, model, or application may be reused to demonstrate the solution. Building a new agent is optional, and agents, applications, and unrelated supporting components are not themselves the assessment target. [C, p. 2, section 3.1.a; p. 3, section 5][criteria]

## 3. Functional requirements

### 3.1. Interception and centralized policy

| ID | Level | Requirement | Source |
| --- | --- | --- | --- |
| FR-01 | Required | Provide a functional control layer that intercepts and governs interactions with AI systems and can be integrated by developers. | [C, p. 2, sections 2 and 3.1][criteria] |
| FR-02 | Required | Enforce security, privacy, and resource controls supplied by a centralized configuration source. A file, system, or control catalog is acceptable. | [C, p. 2, section 2; p. 3, section 4.1][criteria] |
| FR-03 | Required | Manage controls, sensitivity thresholds, allowed LLM models, and resource or financial budgets through that single configuration source. | [C, p. 3, section 4.1][criteria] |
| FR-04 | Required | Support configurable enforcement sensitivity or strictness. The sources describe blocking versus redaction and adherence percentages as configuration examples, and require a sample policy demonstrating different strictness or adherence levels. | [C, p. 2, section 3.2; p. 3, section 4.1][criteria] |

**Suggested verification:** identify the authoritative policy source, demonstrate its effect on a governed interaction, and show examples of different sensitivity settings, model permissions, and budget rules. Document the configuration format and how a change becomes active. Do not assume a specific policy language or a hot-reload mechanism is prescribed.

### 3.2. Hybrid security enforcement

| ID | Level | Requirement | Source |
| --- | --- | --- | --- |
| FR-05 | Required | Use a hybrid defense architecture containing both deterministic, non-AI controls and semantic, AI-based controls. | [C, p. 2, section 2][criteria] |
| FR-06 | Required | Implement deterministic controls. Pattern matching for personal data or secrets and authentication or access checks are examples of suitable techniques. | [C, p. 3, section 4.2.1][criteria] |
| FR-07 | Required under section 2 | Include AI-based semantic enforcement in the hybrid architecture. Section 4.2.2 uses softer language about considering AI where possible; retain this wording discrepancy rather than treating semantic enforcement as unambiguously optional. | [C, p. 2, section 2; p. 3, section 4.2.2][criteria] |
| FR-08 | Required | Inspect interactions and support real-time redaction or blocking of unsafe interactions. | [C, p. 1, section 1][criteria] |
| FR-09 | Required coverage of the stated problem | Address input validation and output filtering in the control-layer design, including unsafe instructions on input and sensitive information returned on output. The source does not prescribe a specific detector for either direction. | [C, p. 1, section 1; p. 2, section 2][criteria] |

**Suggested verification:** demonstrate a harmless allowed interaction, a deterministic detection, a semantic detection, a blocked unsafe interaction, and a redacted interaction. Include input and output cases for the controls that operate in those directions. Show which control and policy explain the outcome.

The source does not require every control to use AI, every control to support redaction, or one particular ordering of deterministic and semantic checks. The intended balance is efficient enforcement with semantic understanding. [C, p. 2, section 2][criteria]

### 3.3. Budget and resource governance

| ID | Level | Requirement | Source |
| --- | --- | --- | --- |
| FR-10 | Required | Include configurable budget controls and demonstrate their implementation in the executable test suite. Budget configuration is a formal requirement, and testing budget limits is a specified outcome. | [C, p. 2, section 3.2; p. 3, sections 3.4 and 4.1][criteria] |
| FR-11 | Recommended design coverage | Consider how to enforce resource and financial limits. Resource access, compute time, and LLM token spending are examples, not a requirement to implement every possible accounting dimension. | [C, p. 3, section 4.3][criteria] |
| FR-12 | Recommended design coverage | Address budget management for both external commercial APIs and locally hosted models. Explain which controls apply to each supported environment. | [C, p. 2, section 2][criteria] |

**Suggested verification:** demonstrate permitted usage below a configured limit and the system's enforcement when that limit would be exceeded. Show budget usage in reporting. Use controlled or simulated usage where appropriate to make test outcomes reproducible; the sources do not require purchasing commercial API access.

The PDFs do not define pricing tables, accounting periods, budget ownership, reset rules, reservation semantics, or the required response to partially completed work. These remain implementation choices to document, not externally imposed requirements.

### 3.4. Historical exploits and evolving threats

| ID | Level | Requirement | Source |
| --- | --- | --- | --- |
| FR-13 | Required deliverable coverage; approach left open | Include exploit mitigation among the controls demonstrated by the executable test suite. The formal section asks teams to consider detection and blocking of historical exploit patterns; the outcome explicitly includes testing exploit mitigation. | [C, p. 3, sections 3.4 and 4.4][criteria] |
| FR-14 | Recommended | Consider how signatures for known attacks can be supplied by an externally managed system. No feed provider, transport, format, or update interval is specified. | [C, p. 2, section 2][criteria] |
| FR-15 | Recommended | Analyze the AI ecosystem and available security sources, such as OWASP, to identify additional controls for emerging risks beyond the examples in the task. | [C, pp. 1-2, section 1][criteria] |

**Suggested verification:** demonstrate a supported historical exploit pattern being stopped and a benign comparison being allowed. If a signature feed is supported, change a signature and show the effect after the documented update process. Do not claim comprehensive coverage of all historical AI vulnerabilities based on a few demonstrations.

### 3.5. Dashboard, reporting, and auditing

| ID | Level | Requirement | Source |
| --- | --- | --- | --- |
| FR-16 | Required | Provide reporting suitable for both security teams and management. | [C, p. 2, section 2; p. 3, section 4.5][criteria] |
| FR-17 | Required deliverable | Provide a simple interactive dashboard displaying controls, overall security posture, blocked threats, and other metrics. Resource consumption and cost are examples of additional metrics. | [C, p. 3, section 3.3][criteria] |
| FR-18 | Required | Provide real-time management metrics covering blocked interactions and budget usage. | [C, p. 3, section 4.5][criteria] |
| FR-19 | Required | Provide exportable audit logs that allow security teams to analyze threats, policy violations, and system usage. | [C, p. 3, section 4.5][criteria] |

**Suggested verification:** generate allowed, blocked, and redacted interactions and budget activity; inspect the resulting dashboard and metrics; export logs and demonstrate that they explain relevant security and usage events.

The dashboard is explicitly listed as an expected outcome even though the challenge and formal reporting requirement also permit reporting through other mechanisms. Providing non-UI reporting alone leaves that dashboard outcome uncovered. No specific charts, export format, retention period, or definition of a security-posture score is prescribed.

### 3.6. Automated self-testing

| ID | Level | Requirement | Source |
| --- | --- | --- | --- |
| FR-20 | Required | Deliver a complete automated test suite for the controls actually implemented. | [C, p. 2, section 2; p. 3, section 4.6][criteria] |
| FR-21 | Required | Include positive cases that are allowed and negative cases that are blocked or redacted. Cover redaction where it is an implemented control outcome. | [C, p. 2, section 2; p. 3, section 4.6; p. 4, section 6][criteria] |
| FR-22 | Required | Make the suite ready to run by judges and include tests for budget limits and exploit mitigation. | [C, p. 3, section 3.4; p. 4, section 6][criteria] |

**Suggested verification:** run the documented test command in the intended evaluation environment and obtain an understandable pass/fail result. Maintain a mapping from implemented controls to their positive and negative test cases. The PDFs do not prescribe a test framework, test count, or coverage percentage.

## 4. Threat coverage register

The task explicitly says its threat list is illustrative. The following register preserves those examples and the problem each represents; it is not a mandate to build a separate detector for every row.

| ID | Level | Threat or risk described in the source | Relevant control-layer behavior to consider | Source |
| --- | --- | --- | --- | --- |
| TH-01 | Example | Insufficient authentication and impersonation of other actors. | Check identity and authentication requirements at relevant interaction boundaries. | [C, p. 1, section 1; p. 3, section 4.2.1][criteria] |
| TH-02 | Example | Agents accessing resources they should not access or performing harmful, irreversible actions. | Apply access requirements and controls on sensitive actions. | [C, p. 1, section 1][criteria] |
| TH-03 | Example | Prompt injection exploiting the interpretation of natural language as instructions. | Inspect input and assess unsafe instructions using suitable deterministic and semantic controls. | [C, p. 1, section 1][criteria] |
| TH-04 | Example | Exposure of personally identifiable information (PII), secrets, or other sensitive data. | Detect sensitive content and apply suitable filtering, redaction, or blocking. | [C, p. 1, section 1; p. 3, section 4.2.1][criteria] |
| TH-05 | Example | Unauthorized retrieval from persistent context or shared memory stores. | Govern access to memory and retrieval resources. | [C, p. 1, section 1][criteria] |
| TH-06 | Example | Runaway agent loops and unexpectedly high resource consumption. | Apply supported budget or resource constraints to limit continued consumption. | [C, p. 1, section 1; p. 3, section 4.3][criteria] |
| TH-07 | Example | Malicious code execution associated with historical attacks on AI infrastructure. | Detect and block relevant known exploit patterns. | [C, p. 3, section 4.4][criteria] |
| TH-08 | Example | Unsafe deserialization associated with historical attacks. | Detect and block supported patterns at the boundaries the control layer can observe. | [C, p. 3, section 4.4][criteria] |
| TH-09 | Example | Supply-chain exploits targeting model repositories. | Consider relevant signatures and controls within the chosen integration scope. | [C, p. 3, section 4.4][criteria] |

For each implemented control, the team should describe the threat it addresses and its detection limits. This is a suggested documentation practice, not evidence that the control layer can inspect operations outside its integration boundaries.

## 5. Non-functional requirements and quality expectations

| ID | Level | Requirement or evaluation expectation | Source |
| --- | --- | --- | --- |
| NFR-01 | Required qualitative property | Keep the control layer lightweight, flexible, and easy for developers to integrate. No maximum package size or integration-time target is given. | [C, p. 2, sections 2 and 3.1][criteria] |
| NFR-02 | Required qualitative property / Evaluation | Support real-time inspection and enforcement while balancing speed and semantic understanding. Architecture and performance efficiency are scored; no numerical latency or throughput target is specified. | [C, p. 1, section 1; p. 2, section 2; p. 4, section 8][criteria] |
| NFR-03 | Evaluation | Show robust control behavior under both the team's own tests and spontaneous judge interactions. No detection-rate target or guarantee of stopping every attack is specified. | [C, p. 4, sections 6 and 8][criteria] |
| NFR-04 | Evaluation | Make the effects of changing rules, removing controls, and adjusting thresholds observable and explain how configuration changes take effect. Real-time adaptation may be explored by judges, but hot reload is not explicitly mandated. | [C, p. 4, section 6][criteria] |
| NFR-05 | Recommended / Evaluation | Be able to produce performance telemetry for evaluation. Metric names and a benchmark methodology are not prescribed. | [C, p. 4, section 6][criteria] |
| NFR-06 | Evaluation | Demonstrate practical implementability and scalability. No mandatory cluster topology, availability objective, or deployment platform is specified. | [C, p. 4, section 8][criteria]; [R, p. 2, clause 11][rules] |
| NFR-07 | Constraint | Ensure the complete system can be designed, built, and run on the team's own setup without relying on organizer-provided paid subscriptions, datasets, or hardware. | [C, p. 4, section 7][criteria] |

**Suggested evidence:** setup and integration instructions, a clear architecture diagram, representative enforcement timing measurements, a documented policy-update procedure, and an explanation of scaling constraints. These evidence formats are suggestions unless separately listed as required deliverables.

## 6. Technology and resource constraints

| ID | Level | Condition | Source |
| --- | --- | --- | --- |
| ENV-01 | Permitted choice | Choose any suitable technology stack. Go, Rust, and Python are examples, not required languages. Building from scratch or on existing open-source tools is permitted. | [C, p. 3, section 5][criteria] |
| ENV-02 | Constraint | Check the licenses of existing open-source tools used in the solution. | [C, p. 3, section 5][criteria] |
| ENV-03 | Permitted choice | Reuse existing agents, models, and applications. A custom agent is optional. | [C, p. 2, section 3.1.a; p. 3, section 5][criteria] |
| ENV-04 | Constraint | No pre-packaged datasets, proprietary APIs, or specific hardware resources are provided for the challenge. | [C, p. 4, section 7][criteria] |
| ENV-05 | Constraint | No paid-service subscriptions are provided, including the named examples OpenAI, Anthropic, and Copilot. This does not establish a prohibition on resources the team already has. | [C, p. 4, section 7][criteria] |
| ENV-06 | Recommended / stated expectation | Use publicly available open-source libraries where necessary, local models, and self-created test prompts to demonstrate and validate the solution. Ollama is an example, not a mandated runtime. | [C, p. 4, section 7][criteria] |

This repository uses Phoenix, but that is a project choice, not an organizer requirement. This specification introduces no application routes, API contracts, database schemas, model vendors, or infrastructure dependencies.

## 7. Required deliverables

| ID | Level | Deliverable | Completion evidence | Source |
| --- | --- | --- | --- | --- |
| DEL-01 | Required | Functional AI Control Layer. | A working component integrated into a demonstration workflow using an existing or custom agent or other suitable AI system. | [C, p. 2, section 3.1][criteria] |
| DEL-02 | Recommended in the source; included in this delivery checklist | Simple architecture diagram. | A diagram presenting the solution's components and their interactions. | [C, p. 2, section 3.1.b][criteria] |
| DEL-03 | Required | Documented sample policy file. | Examples configuring controls, different strictness or adherence levels, and budget rules. | [C, p. 2, section 3.2][criteria] |
| DEL-04 | Required | Simple interactive dashboard. | Visible controls, overall security posture, blocked threats, and relevant metrics. | [C, p. 3, section 3.3][criteria] |
| DEL-05 | Required | Executable automated test suite. | Ready-to-run verification of implemented controls, positive and negative cases, budget limits, and exploit mitigation. | [C, p. 3, section 3.4; p. 4, section 6][criteria] |
| DEL-06 | Required capability | Management reporting and exportable security audit evidence. | Real-time blocked-interaction and budget metrics plus exportable logs about threats, violations, and usage. | [C, p. 3, section 4.5][criteria] |

The evidence column describes how to recognize the deliverable. It does not prescribe packaging, file formats beyond those explicitly required, or a new architecture.

## 8. Validation and acceptance scenarios

Judges primarily rely on the team's deliverables and spontaneous actions requiring no preparation of test cases by the team. They will run the submitted suite and may interact with the running layer, change configuration or feeds, and inspect telemetry, architecture, dashboards, and logs. [C, p. 4, section 6][criteria]

The scenarios below are **suggested verification methods** grounded in that evaluation approach. Expected behavior must follow the implemented control and documented policy, not a hard-coded demonstration response.

| ID | Scenario | Expected evidence | Requirement and source |
| --- | --- | --- | --- |
| VAL-01 | Send a benign interaction through the demonstration integration. | The interaction is allowed and the intended application or agent workflow remains usable. | FR-01, FR-21; [C, p. 2, sections 2 and 3.1][criteria] |
| VAL-02 | Submit a prohibited pattern recognized by a deterministic control. | The configured control produces the appropriate enforcement outcome, while a benign comparison is allowed. | FR-06, FR-08, FR-21; [C, p. 3, sections 4.2.1 and 4.6][criteria] |
| VAL-03 | Submit unsafe content addressed by a semantic control and a benign comparison. | The AI-based control demonstrably participates in enforcement; results and limitations are explainable. | FR-05, FR-07, FR-21; [C, p. 2, section 2][criteria] |
| VAL-04 | Exercise supported input and output controls with sensitive or unsafe content. | Unsafe interactions are blocked or content is redacted according to policy; supported redaction behavior is tested. | FR-08, FR-09, FR-21; [C, p. 1, section 1; p. 2, section 2][criteria] |
| VAL-05 | Change strictness or a sensitivity threshold; repeat a relevant interaction. | Behavior reflects the active configuration according to the documented update procedure. | FR-04, NFR-04; [C, p. 2, section 3.2; p. 4, section 6][criteria] |
| VAL-06 | Change or remove a control and modify an allowed-model setting. | Enforcement reflects the active policy; the team can explain when the change took effect. | FR-02, FR-03, NFR-04; [C, p. 3, section 4.1; p. 4, section 6][criteria] |
| VAL-07 | Exercise usage below and beyond a configured budget limit. | Valid usage is permitted and the implemented budget control enforces its limit; reporting shows usage. | FR-10, FR-18; [C, p. 3, sections 3.4 and 4.5][criteria] |
| VAL-08 | Demonstrate budget treatment for commercial APIs and local models within the supported design. | The team explains or demonstrates applicable financial and resource controls and any unsupported dimensions. | FR-11, FR-12; [C, p. 2, section 2; p. 3, section 4.3][criteria] |
| VAL-09 | Submit a supported historical exploit pattern and a benign comparison. | The exploit mitigation works, and normal use remains possible. | FR-13, FR-22; [C, p. 3, sections 3.4 and 4.4][criteria] |
| VAL-10 | If external signatures are supported, change a feed entry and repeat a relevant interaction. | The update affects detection through the documented feed/configuration process. | FR-14, NFR-04; [C, p. 2, section 2; p. 4, section 6][criteria] |
| VAL-11 | Generate representative interactions and review dashboard, metrics, and exported logs. | Controls, security posture, blocked threats, budget usage, and security audit evidence are inspectable. | FR-16 through FR-19; [C, p. 3, sections 3.3 and 4.5][criteria] |
| VAL-12 | Run the complete suite using the supplied instructions. | Judges obtain usable results for all implemented controls, including budget and exploit cases. | FR-20 through FR-22; [C, p. 3, section 3.4; p. 4, section 6][criteria] |
| VAL-13 | Submit an ad-hoc prompt not included in the team's prepared demonstrations. | The running control layer evaluates it under the active policy, and its reaction can be observed. | NFR-03; [C, p. 4, section 6][criteria] |
| VAL-14 | Inspect the architecture and collect representative performance telemetry. | The team can explain control placement, integration, performance costs, and practical scaling considerations. | NFR-01, NFR-02, NFR-05, NFR-06; [C, p. 4, sections 6 and 8][criteria] |

## 9. Evaluation criteria and scoring conflict

### 9.1. Task-description scoring

Source: [C, p. 4, section 8][criteria].

| Criterion | Weight |
| --- | ---: |
| Robustness of the Solution and Quality of Guardrails | 30% |
| Architecture and Performance Efficiency | 20% |
| Security Reporting | 20% |
| Completeness of the Self-Testing Suite | 15% |
| Practical Implementability and Scalability | 15% |
| **Total** | **100%** |

### 9.2. Competition-regulation scoring

Source: [R, p. 2, clause 11][rules].

| Criterion | Weight |
| --- | ---: |
| Robustness of the Solution and Quality of Guardrails | 30% |
| Architecture and Performance Efficiency | 20% |
| Security Reporting | 20% |
| Completeness of the Self-Testing Suite | 20% |
| Practical Implementability and Scalability | 10% |
| **Total** | **100%** |

**Unresolved conflict:** test-suite completeness and practical implementability/scalability have different weights in the two documents. Obtain organizer clarification before treating either table as authoritative. Neither table specifies internal subcriteria or additional numerical acceptance targets.

## 10. Submission and participation requirements

These are competition conditions, separate from system behavior. This section summarizes the supplied regulations; it does not add requirements from general HackYeah rules that were not supplied.

| ID | Level | Requirement or condition | Source |
| --- | --- | --- | --- |
| SUB-01 | Constraint | Participate individually or as a team of up to six people. | [R, p. 1, clause 5][rules] |
| SUB-02 | Constraint | Start solving the competition task no earlier than **11:00 PM on October 3** and submit it for evaluation no later than **11:00 PM on October 4**, as written in the supplied regulations. The year and timezone are not specified there. | [R, p. 1, clause 5][rules] |
| SUB-03 | Required submission content | Include the project title, team name, list of 1-6 members, and project description. | [R, p. 1, clause 5.a-d][rules] |
| SUB-04 | Required submission content | Include a PDF presentation of no more than 10 slides. | [R, p. 1, clause 5.e][rules] |
| SUB-05 | Constraint | Submit through HackTribe in English or Polish. | [R, p. 1, clause 5][rules] |
| SUB-06 | Permitted supporting material | Include screenshots, a code repository, demo links, graphics, or other project-related materials as appropriate. These are optional submission attachments under this clause; the technical deliverables still apply. | [R, p. 1, clause 5.e][rules] |
| SUB-07 | Constraint | Do not alter the submitted solution after the permitted time expires; post-deadline changes are prohibited and will not be considered by the jury. | [R, p. 3, clause 13][rules] |
| SUB-08 | Constraint | Observe the participation exclusion involving relatives or relatives by marriage of jury members and the employees described in clause 6. Consult that clause or the organizer if eligibility is uncertain. | [R, p. 2, clause 6][rules] |
| SUB-09 | Evaluation | Phase 1 evaluates HackTribe submissions through a commission of at least three mentors; selected finalists present live to a jury in phase 2. The two groups may overlap. | [R, p. 2, clause 8][rules] |
| SUB-10 | Constraint for receiving an award | The project must receive at least 50% of the points in the first evaluation stage to receive an award. Jury decisions are final and cannot be appealed under these regulations. | [R, p. 2, clause 12][rules] |

### Additional competition information

- The supplied competition rules are an annex to the general HackYeah regulations. Those general regulations are outside the provided source set. [R, p. 1, clause 1][rules]
- The regulations name Proidea Sp. z o.o. as the sponsor and entity promising the prize. Task details are to be presented at the competition start. [R, p. 1, clauses 2-3][rules]
- The prize pool is PLN 15,000 including tax: PLN 6,000 for first place, PLN 5,000 for second, and PLN 4,000 for third. Prizes are issued within 90 days after results unless the applicable competition rules specify otherwise. [R, p. 1, clause 4; p. 2, clause 7][rules]
- Jury members select a chairperson. Clause 10 says the jury's vote decides a tie in either phase; it does not explicitly assign a chairperson's casting vote. [R, p. 2, clauses 9-10][rules]
- The author's proprietary copyrights to an awarded solution are not transferred to the competition sponsor. [R, p. 3, clause 14][rules]
- Jury membership is to be announced on the HackYeah Discord communication platform no later than October 4. [R, p. 3, clause 15][rules]

## 11. Ambiguities and decisions not made by the sources

| ID | Issue | Treatment in this specification | Source |
| --- | --- | --- | --- |
| OPEN-01 | Conflicting scoring weights. | Retain both tables and request organizer clarification; do not silently select one. | [C, p. 4, section 8][criteria]; [R, p. 2, clause 11][rules] |
| OPEN-02 | Competition dates omit the year and timezone and explicitly use PM. | Preserve the original times. Do not infer a year or timezone from the repository name or local machine, or change PM to AM. | [R, p. 1, clause 5][rules] |
| OPEN-03 | Hybrid AI enforcement is mandatory in the challenge but phrased as a consideration in the formal list. | Use the explicit hybrid requirement as the baseline and flag the difference in strength. | [C, p. 2, section 2; p. 3, section 4.2.2][criteria] |
| OPEN-04 | Reporting may be provided through various mechanisms, but the outcome explicitly includes an interactive dashboard. | Include the dashboard deliverable; other reporting mechanisms can supplement it. | [C, p. 2, section 2; p. 3, sections 3.3 and 4.5][criteria] |
| OPEN-05 | Budget and historical-exploit sections use design-oriented wording, while expected tests include both capabilities. | Require demonstrable implemented budget and exploit controls; retain examples of resource types and attacks as examples. | [C, p. 3, sections 3.4 and 4.3-4][criteria] |
| OPEN-06 | Judges may explore configuration changes in real time, but no reload contract is specified. | Explain and demonstrate the chosen update behavior without inventing a mandatory zero-restart requirement or propagation deadline. | [C, p. 4, section 6][criteria] |
| OPEN-07 | No mandatory control catalog, protocol set, metric thresholds, or feed format is defined. | Document the implementation's supported coverage and limitations; do not present design choices as organizer mandates. | [C, pp. 1-3, sections 1-5; p. 4, section 6][criteria] |
| OPEN-08 | General HackYeah rules are referenced but not included. | Do not claim this document covers obligations in documents outside the supplied source set. | [R, p. 1, clause 1][rules] |

Implementation details such as API routes, database design, authentication mechanisms, model selection, audit-log retention, outage behavior, pricing formulas, and deployment topology remain open design choices. This document does not choose an MVP or impose additional mandatory features.

## 12. Completion checklist

This checklist describes work to verify before delivery; unchecked items do not constitute an assessment of the current repository.

### System and technical deliverables

- [ ] A functional control layer is demonstrated through a supported integration. **FR-01, DEL-01**
- [ ] Central configuration manages controls, sensitivity, allowed models, and budgets. **FR-02 through FR-04**
- [ ] Both deterministic and AI-based semantic enforcement are present. **FR-05 through FR-07**
- [ ] Input and output risks are addressed; supported blocking and redaction are demonstrated. **FR-08, FR-09**
- [ ] Implemented budget limits are configured and tested. **FR-10, FR-22**
- [ ] Budget handling for commercial APIs and local models has been considered and its coverage documented. **FR-11, FR-12; recommended design coverage**
- [ ] Implemented exploit mitigation is demonstrated and tested. **FR-13, FR-22**
- [ ] External signatures and threats beyond the supplied examples have been considered. **FR-14, FR-15; recommendations**
- [ ] The interactive dashboard and management metrics are available. **FR-16 through FR-18, DEL-04**
- [ ] Security logs can be exported and support analysis of threats, violations, and usage. **FR-19, DEL-06**
- [ ] Judges can run the suite with positive and negative cases for implemented controls. **FR-20 through FR-22, DEL-05**
- [ ] The sample policy is documented and demonstrates strictness and budget configuration. **DEL-03**
- [ ] A simple architecture diagram is prepared. **DEL-02; source recommendation**
- [ ] Configuration-change behavior can be explained and demonstrated. **NFR-04**
- [ ] Performance telemetry can be produced, and scaling considerations can be explained. **NFR-05, NFR-06**
- [ ] The system runs on the team's setup, and licenses of reused tools have been checked. **NFR-07, ENV-02 through ENV-06**

### Competition readiness

- [ ] The scoring discrepancy has been raised with the organizer and any clarification recorded. **OPEN-01**
- [ ] The competition year, timezone, and stated PM timing have been confirmed without silently rewriting the source. **OPEN-02, SUB-02**
- [ ] Team size and eligibility conditions have been checked. **SUB-01, SUB-08**
- [ ] Project title, team name, member list, description, and a PDF of at most 10 slides are ready. **SUB-03, SUB-04**
- [ ] The submission is prepared for HackTribe in English or Polish. **SUB-05**
- [ ] The team is prepared for ad-hoc prompts, policy changes, test execution, and a finalist presentation if selected. **VAL-05, VAL-06, VAL-12, VAL-13, SUB-09**
- [ ] The submitted version will be preserved after the deadline. **SUB-07**

[criteria]: <Partner Task [Goldman Sachs] - AI Control Layer/CRIETRIA AI Control Layer.pdf>
[rules]: <Partner Task [Goldman Sachs] - AI Control Layer/RULES AI Control Layer.pdf>
