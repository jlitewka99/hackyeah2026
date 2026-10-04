---
version: 1
slug: organization-reporting
primary_target: lib/ai_control_web/live/organization_overview_live.ex
related_targets: [lib/ai_control_web/live/organization_events_live.ex, lib/ai_control_web/live/organization_event_live.ex, lib/ai_control_web/live/organization_budgets_live.ex, lib/ai_control_web/live/organization_signatures_live.ex, lib/ai_control_web/components/reporting_html.ex]
---

# Organization reporting · Step 11A

Mode: Operate. This is an ordinary extension of the established workspace.
Build path: code, as recorded in `.impeccable/config.json`. No comp applies.

## Direction contract

THESIS: Connect durable security evidence and resource accounting to the existing workspace, making a request's outcome, measured latency and budget effect understandable together.

OWN-WORLD: Preserve the neutral light/dark tokens, system sans, thin separators, tabular numerals, compact controls and existing workspace navigation. Flat sections, real data and permission-aware links carry the interface. English product copy; no invented security score or imagery.

STORY: Scan decisions, controls and current budget in Overview; narrow the Events timeline; open evidence for one request; export the same selection; inspect current budgets or the pinned signature catalog. Policy editing remains in Policies.

FIRST VIEWPORT: Desktop navigation rail and mobile header remain. The organization and page title identify scope; the reporting range precedes a balanced activity section. Events leads with filters and export. Budget and signature pages lead with the current UTC hour or pinned catalog identity. On narrow screens rows stack without hiding evidence or actions.

FORM: User selected balanced Overview and read-only Budgets/Signatures. Signature interaction: URL-backed event filters stay shareable; content-free updates coalesce without remounting the page or overwriting open Agents/Policies forms. Motion inherits the existing short hover/focus transitions and reduced-motion rules.

FINISH: Unreviewed and undocumented is unfinished. Finish reviewer receives all new routes at 1440×1000 and 390×844, both themes, plus empty/invalid filter evidence. Documenter compares this extension with the incumbent system without refreshing DESIGN.md or its stale sidecar.

## Scope and truth

Current organization and refreshed grants constrain every read. Independent events, budgets, signatures and policies grants control sections and links. Terminal request counts deduplicate phase evidence. Nearest-rank p50/p95 show sample counts and milliseconds; missing observations stay unrecorded. Budget totals cover the organization, agent rows cover assigned agents. Costs stay separated by currency. Pattern matches and tool proposals do not prove execution; full tool integration and MVP acceptance remain 12B/11B.

## Acceptance evidence

The documenter opened all 26 supplied captures: the 20-file matrix at `.impeccable/review/{overview,events,budgets,signatures,event-detail}-{desktop-light,desktop-dark,mobile-light,mobile-dark}.png`, plus Agents/Policies desktop-light, the final Overview viewport, mobile keyboard navigation, and empty/invalid Events filters. The matrix has 1440px desktop and 390px mobile widths; the build thread reports capture viewports of 1440×1000 and 390×844, with full-page image heights extending beyond those viewports. Synthetic fixture data is explicitly labeled **Synthetic demonstration**.

Source and capture comparison confirms an ordinary extension of the incumbent neutral light/dark workspace: compact system sans, semantic colors, thin separators, existing controls, tabular reporting numerals, flat sections, and stacked evidence rows. The expanded mobile navigation uses a native disclosure and retains its destinations, account identity, appearance controls and visible keyboard focus. Budgets and Signatures remain read-only. Detailed checked evidence is in [Step 11A design documentation](../../docs/acceptance/step11a-design-documentation.md).

The [finish review](../../docs/acceptance/step11a-ui-review.md) records an initial full review with one material accessibility fix: the p50 value lacked `role="cell"`. Current source supplies that role. The final **ship** verdict scores that sole fix and checks for fix-induced regressions across the recaptured evidence; it is not a new full-surface review. The supplied detector result has no primary findings and five typography advisories. Those advisories are recorded without promoting their values to normative tokens.

`DESIGN.md`, `.impeccable/design.json`, `PRODUCT.md` and configuration were preserved. No new visual world or durable system change was approved. Existing sidecar drift remains recorded in the implementation plan and deferred, as requested, to a separate `impeccable document` task. These synthetic UI captures do not establish real-model performance or complete Steps 11B/12B.
