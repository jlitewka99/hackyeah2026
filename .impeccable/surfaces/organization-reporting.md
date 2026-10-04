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

Current organization and refreshed grants constrain every read. Independent events, budgets, signatures and policies grants control sections and links. Terminal request counts deduplicate phase evidence and exclude the nonterminal `tool.dispatching` event. Nearest-rank p50/p95 show sample counts and milliseconds; missing observations stay unrecorded. Budget totals cover the organization, agent rows cover assigned agents. Costs stay separated by currency. Pattern matches and tool proposals do not prove execution. Step 12B tool execution is now on main; the reporting integration projects only `execution_id`, `workflow_id`, `execution_status`, `tool` and `charged` receipt fields into Event details and JSONL export, and notifies reporting after successful receipt commits. Joint MVP and real-model qualification remain Step 11B.

## Acceptance evidence

The initial documentation handoff opened all 26 supplied captures: the 20-file matrix at `.impeccable/review/{overview,events,budgets,signatures,event-detail}-{desktop-light,desktop-dark,mobile-light,mobile-dark}.png`, plus Agents/Policies desktop-light, the final Overview viewport, mobile keyboard navigation, and empty/invalid Events filters. The matrix has 1440px desktop and 390px mobile widths; the build thread reports capture viewports of 1440×1000 and 390×844, with full-page image heights extending beyond those viewports. Synthetic fixture data is explicitly labeled **Synthetic demonstration**. These captures precede the final backend integration and later main tool-policy UI/styles; they do not test those later changes.

At the initial handoff, source and capture comparison confirmed an ordinary extension of the incumbent neutral light/dark workspace: compact system sans, semantic colors, thin separators, existing controls, tabular reporting numerals, flat sections, and stacked evidence rows. The expanded mobile navigation uses a native disclosure and retains its destinations, account identity, appearance controls and visible keyboard focus. Budgets and Signatures remain read-only. After rebasing onto main's Step 12B merge `84a8f2d`, one factual Budgets footer correction replaced the statement that tool reporting was not connected with **Workflow execution receipts are available in Events.** Current template diff confirms this copy change; the build thread reports no other reporting template changes and no reporting layout/style changes. The documentation recheck sampled the final backend changes described above and opened the four additional Budgets captures below, without rerunning the detector or starting a new full UI review. Detailed checked evidence is in [Step 11A design documentation](../../docs/acceptance/step11a-design-documentation.md).

The four additional `.impeccable/review/budgets-integrated-{desktop-light,desktop-dark,mobile-light,mobile-dark}.png` captures were opened for the footer correction. All show the corrected sentence under Effective limits; it fits the existing footer in both themes at 1440px desktop and wraps within the content region at 390px mobile. These supplement the historical 26-capture acceptance only for this correction. The finish reviewer conducts a separate targeted footer/regression recheck; neither this documentation check nor the earlier captures qualifies main's other later UI changes.

The [finish review](../../docs/acceptance/step11a-ui-review.md) records an initial full review with one material accessibility fix: the p50 value lacked `role="cell"`. Current source supplies that role. The original **ship** verdict scores that sole fix and checks for fix-induced regressions across the recaptured evidence; it is not a new full-surface review or acceptance of the later main changes. The earlier supplied detector result has no primary findings and five typography advisories. Those advisories are recorded without promoting their values to normative tokens.

`DESIGN.md`, `.impeccable/design.json`, `PRODUCT.md` and configuration were preserved. No new visual world or durable system change was approved for Step 11A. Existing sidecar drift remains recorded in the implementation plan and deferred, as requested, to a separate `impeccable document` task. These synthetic UI captures do not establish real-model performance or complete the joint MVP/model qualification in Step 11B; Step 12B is now on main.

## Step 11B provider evidence extension — 2026-10-04

The Overview active-controls rows now name the effective injection and response-moderation providers using the shared readable provider labels. Event details explain the historical semantic signal from serialized audit evidence: Prompt Guard shows the recorded maximum malicious score, window count and recorded policy threshold; Qwen explains selected severity and Jailbreak label mapping. Missing observations remain unrecorded, scores are explicitly not calibrated probabilities, and model proposals remain distinct from tool execution. Changing the active policy does not reinterpret historical evidence. The additions preserve the existing permission boundaries, separate LiveView modules/HEEx templates, streamed chronology, safe evidence region, neutral themes, compact system type, thin separators and mobile wrapping.

The thirteen supplied `step11b-*.png` captures are exactly 1440×1000 on desktop and 390×844 on mobile. The documentation comparison opened the Overview capture and light desktop/dark mobile Event details captures alongside five policy/control/error samples; the build handoff reports opening the complete set and checking keyboard and permissions. The existing detector result is `[]` and was not rerun. The finish review returned `ship` after the sole readable policy-comparison correction; its final regression recheck is scoped to the two corrected diff captures. This evidence records the reporting extension and does not extend Step 11A acceptance to a complete MVP or live-model comparison. Approved Prompt Guard weights are absent, and live comparison and Docker verification remain blocked.

PRODUCT.md, DESIGN.md, configuration and `.impeccable/design.json` remain unchanged. Existing historical product wording, system documentation predating the built workflows, and the stale sidecar are reported without repair or promotion into new design rules; this code-led extension does not authorize a system refresh.
