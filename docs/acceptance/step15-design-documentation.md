# Step 15 design documentation recheck

Checked 2026-10-04 using the shipped Impeccable documenter role and its previously read full `reference/document.md`. This is an ordinary Operate extension of the incumbent reporting workspace. `PRODUCT.md`, `DESIGN.md`, and `.impeccable/design.json` were preserved; no durable system refresh was authorized. This pass did not operate a browser, rerun the detector, or run application tests.

## Source evidence

Compared `assets/css/app.css`, `organization_runs_live.html.heex`, `organization_run_live.html.heex`, and `components/policy_html/panel.html.heex` against the incumbent system and `.impeccable/surfaces/organization-workflows.md`. The final recheck additionally sampled both paired LiveViews, `assets/js/app.js`, and the acceptance and finish-review records.

The source inherits semantic light/dark colors, the system sans family, existing rounded controls, thin ruled sections, tabular accounting values, and shared reporting rows. Workflow filters and rows stack at 640px; the existing shell stacks at 767px. The detail exposes shared root usage, participant depth, terminal state/reason, and an inline stop confirmation rather than introducing a new composition or elevation vocabulary.

Final source distinguishes hourly budgets from legacy agent-context tool limits and v5 shared workflow limits. V5 workflow inputs have `required`, nonnegative integer constraints, and “Finite limit required” placeholders. These are source-level UI checks, not proof of backend enforcement. Workflow-state failure has its own alert and disables management; event-history failure has a separate alert. List and event empty states now sit outside their streamed collections, use explicit empty assigns, and are suppressed by their respective errors. Event access and manage access remain separately checked in the sampled source.

Request, cancel, and successful committed-stop handlers push fixed-target `workflow-focus` events. The bundle permits only confirmation, Stop workflow, and status targets and focuses the corresponding element after the LiveView update. Status has `tabindex="-1"` and `aria-live="polite"`. These checks establish the focus implementation; browser behavior remains separately attributed below.

## Supplied rendered evidence

The initial documentation pass opened all 14 supplied full-page captures in `.impeccable/review/`:

| Surface | Light desktop/mobile | Dark desktop/mobile |
| --- | --- | --- |
| List | `desktop.png`, `mobile.png` | `desktop-dark.png`, `mobile-dark.png` |
| Detail | `desktop-detail.png`, `mobile-detail.png` | `desktop-detail-dark.png`, `mobile-detail-dark.png` |
| Policy v5 | `desktop-policy.png`, `mobile-policy.png` | `desktop-policy-dark.png`, `mobile-policy-dark.png` |

Also opened `mobile-stop-confirmation.png` and `mobile-stopped.png`, both dark. The supplied matrix has 1280px desktop and 390px mobile document widths. Synthetic labeling is visible in organization identity and workflow goals. The images show neutral surfaces, consistent controls and rules, wrapped long goals, stacked mobile rows, shared-limit values, participants, audit rows, the inline confirmation, and a stopped state with feedback. Policy views show schema v5 and populated workflow budget fields. Full-page policy previews were automatically reduced for viewing; the exact final budget copy and required attributes were checked in source.

The builder recaptured the ten list/detail/stop paths after the final fix batch and reports opening them all; policy images were unchanged at that stage. The fix-batch documenter recheck opened the replaced `mobile-stop-confirmation.png` and `mobile-stopped.png` plus supplemental `desktop-error.png`, `mobile-error.png`, and `mobile-empty.png`. Both error images display invalid-filter feedback without the no-match message; the genuine empty image displays the no-match message without an error. Confirmation shows the visible outline on Stop workflow. The stopped capture shows an outlined Stopped status, removed confirmation, and retained 140 used and 400 reserved tokens.

These are supplied snapshots, not interactions performed by this documenter. The builder's recorded DOM observations establish confirmation focus at `run-stop-confirm`, cancellation focus at `run-stop`, and committed focus at `run-status`; this recheck independently establishes only the visible captured states and sampled source. [Step 15 acceptance](step15.md) records the builder's interactions and test results. The separate [FULL and verdict review](step15-ui-review.md) returned `fix` then scoped `ship`: both the empty/error contradiction and focus continuity fixes resolved. That verdict scores those two material fixes, not whole-surface qualification.

## Merged policy compatibility recheck

After integration with current main `6366bd9` (Step 18), sampled current `PolicyHTML`, the policy template, and navigation in `layouts.ex`. V5 Knowledge/retrieval, explicit memory-write, source/trust selection, and pinned NER rule-set controls coexist with finite workflow fields. `PolicyHTML.upgrade_available?/1` detects older schemas or any missing/blank v5 workflow limit; the existing v5 draft action is labeled “Apply workflow defaults”. These are source checks of compatibility presentation, not a new system definition or backend qualification.

Opened all four newly replaced policy capture paths listed in the matrix above. They show the merged Knowledge/NER controls and populated workflow budgets in neutral light/dark appearances, with desktop columns and stacked mobile fields. The full-page images are 1280×4744 and 390×7077 and were reduced for viewing; exact attributes and upgrade conditions were checked in source. The builder reports six required finite fields, no horizontal overflow, and both Knowledge and Workflows navigation links in browser DOM. Source separately gates those links by their own read grants. The review fixture's 1800-second duration is a synthetic override, not the 300-second product default. List/detail/stop source, captures, and the prior two-fix verdict are unchanged by this scoped policy recheck. No new defect hunt, browser operation, detector run, or broader visual approval is implied.

## Final upstream source compatibility note

Main subsequently advanced to `dae70b3` (Step 16 background jobs) and was integrated. This last source-only recheck sampled `layouts.ex`, `assets/css/app.css`, and the policy template. Navigation retains Workflows and Knowledge while adding Reports (`events.read`) and Tests (`tests.read`) with the incumbent navigation component and active-state semantics. Added `.background-*` CSS is namespaced to background-job rows/actions/forms and uses existing rules, spacing, and a 640px stacking breakpoint. Workflow markup/styles remain unchanged. The v5 policy template retains main's `policy-signature-selector` alongside Knowledge/NER controls and finite workflow budgets.

All supplied captures predate these Step 16 navigation and signature-selector additions. Those additions have source and builder-reported test evidence, not newly captured rendered evidence; test results are recorded separately. This note preserves the prior scoped two-fix verdict and does not extend it to the new upstream surfaces. No browser, detector, visual-polishing round, or new design audit was performed.

## System summary and existing drift

- Palette: neutral light/dark surfaces with semantic danger, success, and focus roles.
- Type: 1.75rem headline, 1.0625rem title, 0.9375rem body, 0.875rem control, and 0.8125rem label roles.
- Color rule: The Semantic State Rule continues in errors and workflow status.
- Type/layout rules: The Single Family Rule and Same Task Rule continue through shared controls and responsive composition.
- Depth rule: The Flat Task Rule continues through ruled rows and a bordered inline confirmation.

The existing detector report `/private/tmp/step15-impeccable-detect.json` contains zero primary findings and five pre-existing type advisories: report values at 1.125rem, mobile latency and resource identifiers at 0.75rem, and access legends and mobile YAML at 1rem. They were not rerun, repaired, or added to the normative type ramp to erase findings.

Historical `PRODUCT.md` and system narrative still describe earlier unbuilt reporting/policy capabilities. `DESIGN.md` and its sidecar also lag later mono identifiers, disabled-input treatments, and navigation patterns. Those incumbent discrepancies remain uncanonized and unrepaired because this extension does not authorize historical documentation or system changes.

No primary documenter input is missing. Genuine empty and invalid-filter states now have supplemental rendered evidence, and confirmation/commit focus is visible. Dedicated access-restriction, workflow/event loading-failure, and cancellation-focus browser captures remain absent; source checks and builder-reported tests/DOM observations do not substitute for those images. No separate Operate QUALITY BAR card was supplied, limiting independent ceiling qualification. The direction contract records the final checks and scoped verdict. Live qualification is recorded separately: the builder reports 2/7 cases passed initially (both real v5 RAG cases), then 5/7 on alternate provider ports, with both repeated RAG cases returning `guard_unavailable`. This supersedes any blanket statement that all services are unavailable; those backend results were not validated by this documenter. Overall qualification remains separate from the resolved UI fixes. This report does not grant backend, security, performance, or live-model acceptance.
