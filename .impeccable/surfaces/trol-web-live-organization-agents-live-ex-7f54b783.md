---
version: 1
slug: "trol-web-live-organization-agents-live-ex-7f54b783"
primary_target: "lib/ai_control_web/live/organization_agents_live.ex"
related_targets: ["lib/ai_control_web/live/organization_api_keys_live.ex","lib/ai_control_web/live/organization_agents_live.html.heex","lib/ai_control_web/live/organization_api_keys_live.html.heex"]
---

# Agents and API keys

Mode: Operate. Organization members manage only agents selected by their current grants. Key administrators can work without agent-registry read access. Two separate destinations were selected by the user.

## Direction contract

THESIS: Make registration and credential lifecycle explicit in the existing private workspace. Flat task sections and real resource rows carry the workflow.

OWN-WORLD: Preserve DESIGN.md's neutral light/dark surfaces, system sans typography, thin rules, semantic focus and status colors, and compact 44px controls. No imagery or new brand system.

STORY: Register an agent, issue its key, save the one-time secret, then inspect or revoke it. Rotation warns before atomically replacing the existing credential.

FIRST VIEWPORT: Existing navigation rail on desktop and visible navigation header on mobile. Compact page title and explanation lead into an inline creation form and issued-resource list. A freshly issued secret receives a dedicated section above the form.

FORM: User-confirmed two-section extension of the established workspace; code-led per project configuration. No seed applies to this fixed extension. Signature interaction: one-time secret with copy feedback, explicit dismissal, and immediate removal on disconnect. Motion inherits the existing short hover/focus transitions and reduced-motion rules.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## States and constraints

English copy. Empty lists, long names and UUIDs, suspended agents, expired/revoked keys, inline validation, loading and disabled actions, and loss of access in open views. Same tasks and information on desktop and mobile, in both themes. No unresolved product choices. Gateway, full policy management and the model registry remain later work. Step 4 security and audit infrastructure already exists; auditing agent/key administration remains outside this change.
