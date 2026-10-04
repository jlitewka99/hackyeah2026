# Step 11A design documentation

Initially checked 2026-10-04 using the shipped `impeccable_documenter` workflow for an ordinary extension. Documentation was rechecked after the final backend integration onto main's Step 12B merge `84a8f2d` and the single factual Budgets footer correction. The initial pass records source and supplied synthetic captures from that handoff; the recheck records later backend source and four supplemental Budgets captures separately below. These passes did not operate a browser, rerun the detector, run application tests, or refresh the design tokens.

## Checked evidence

Read `PRODUCT.md`, incumbent `DESIGN.md`, `.impeccable/config.json`, `.impeccable/design.json`, the reporting direction contract, and the shipped documentation reference. Source sampling covered `assets/css/app.css`, the workspace layout, all five reporting HEEx templates and their paired LiveView modules, `ReportingHTML`, and `ReportingLive`.

All 26 capture files were opened in the initial handoff. Each showed its expected route or supplemental state and theme. They precede the final backend integration and later main tool-policy UI/styles, and do not test those later changes. The five-route matrix contains all four desktop/mobile and light/dark combinations:

| Surface | Capture prefix | Observed document widths |
| --- | --- | --- |
| Overview | `overview` | 1440px desktop; 390px mobile |
| Events | `events` | 1440px desktop; 390px mobile |
| Budgets | `budgets` | 1440px desktop; 390px mobile |
| Signatures | `signatures` | 1440px desktop; 390px mobile |
| Event detail | `event-detail` | 1440px desktop; 390px mobile |

Matrix files are `.impeccable/review/<prefix>-{desktop-light,desktop-dark,mobile-light,mobile-dark}.png`. The build thread reports viewport sizes of 1440×1000 and 390×844; these are full-page captures whose image heights vary with content.

Supplemental files checked in the same directory: `agents-desktop-light.png`, `policies-desktop-light.png`, `overview-desktop-final-viewport.png`, `mobile-keyboard-navigation.png`, `events-empty-mobile-light.png`, and `events-invalid-mobile-light.png`. The final Overview viewport file itself measures 1200×1000. The fixture organization is visibly named **Synthetic demonstration**.

## Incumbent system comparison

- **Palette:** reporting styles use the existing semantic surface, ink, rule, focus, danger and success properties. The CSS light/dark values match the incumbent frontmatter and sidecar canonical colors. Captures retain white or graphite surfaces with restrained state colors.
- **Type:** page and section headings retain the established system sans hierarchy (1.75rem and 1.0625rem); body, fields and navigation keep the compact incumbent scale. Reporting counts and measured latency use tabular numerals. Actual identifiers and evidence JSON use a technical monospace treatment in the source.
- **Layout:** the rail, content cap, main padding and quiet dividing rules continue the workspace geometry. Overview puts activity beside current budget on wide screens; the mobile layout stacks those sections, filters, event outcomes, budget-agent values and evidence facts. Long checksums and evidence wrap within the narrow content region.
- **Controls and navigation:** filters reuse the shared form/input components and existing secondary button. Export and event links retain incumbent control/link styling. Native mobile disclosure contains the same workspace destinations; its supplied open-state capture shows visible focus while keeping identity, sign-out and appearance controls available.
- **Named rules:** the extension retains the Semantic State, Single Family, Same Task and Flat Task rules in the incumbent record. CSS carries the existing 180ms state transitions and reduced-motion override. Still captures establish appearance and layout, not motion execution.

The separate `.ex` and `.html.heex` page files preserve the repository convention. Templates wrap content in `Layouts.app` with `current_scope`; reporting collections use streams with stable IDs. Read-only Budgets/Signatures templates contain no policy editor. Source shows URL patches for valid filters, unchanged applied filters on invalid submission, and coalesced reporting notifications. The supplied empty and invalid Events captures show explanatory empty copy and the field error without hiding controls.

## Review scope and preserved drift

The [finish reviewer record](step11a-ui-review.md) contains the initial full review and its single material finding: the p50 span lacked a cell role. Current Overview source includes `role="cell"`. The original **ship** disposition is scoped to scoring that fix and checking its regressions; it does not announce a new full-surface review or acceptance of the later main changes. Browser behavior and test results in that record remain build-thread-reported evidence.

The earlier supplied `/private/tmp/step11-impeccable-detect.json` contains five typography advisories and no primary findings. Its values include the reporting summary size and mobile latency size alongside other workspace styles. This evidence pass neither canonizes those advisory values into the design system nor repairs them; the detector was not rerun after the integration.

No new visual world or approved durable system change was established for Step 11A. `DESIGN.md`, `.impeccable/design.json`, `PRODUCT.md` and `.impeccable/config.json` were left unchanged; application source, implementation plan and reviewer record were not edited by this documenter. The known pre-existing sidecar drift remains deferred to the user's separate `impeccable document` task. Documentation of the extension stays local to this report and the reporting surface brief.

## Final backend integration recheck

Step 12B is now on main at merge `84a8f2d`, which is an ancestor of the reporting branch checked here. Main introduced its own tool-policy UI/styles. After rebasing, the Budgets template received one factual footer correction: **Workflow execution receipts are available in Events.** replaces **Tool execution reporting is not connected in this release.** The current template diff confirms that single copy change. The build thread reports no other reporting template changes and no reporting layout/style changes. The original 26 captures and reviewer verdict retain their historical synthetic UI acceptance scope; this documentation recheck does not qualify main's other later UI changes.

The recheck sampled `Dashboard`, `Audit.Serializer`, `Audit.Export`, `OrganizationEventLive`, `Tools.Executions` and `Audit.notify/1`. Current source establishes these integration facts:

- Overview and per-agent terminal counts exclude the nonterminal `tool.dispatching` gateway event before deduplicating request evidence.
- Event details and JSONL export share the serializer projection of five allowlisted `tool_execution` receipt fields: `execution_id`, `workflow_id`, `execution_status`, `tool` and `charged`.
- The tool-receipt transaction wrapper notifies reporting only after `Repo.transaction/2` returns a successful execution result; failed transactions do not take that notification branch.

These are source checks, not new captured interaction tests or a new UI finish review. Synthetic UI captures do not establish real-model performance, and Step 12B being on main does not complete the joint MVP/model qualification that remains Step 11B.

## Targeted Budgets footer evidence

Opened all four additional captures at `.impeccable/review/budgets-integrated-{desktop-light,desktop-dark,mobile-light,mobile-dark}.png`. Each shows the corrected workflow-receipt sentence under Effective limits. The desktop images are 1440×1967; the mobile images are 390×2902. The sentence fits the incumbent footer region in both desktop themes and wraps within the narrow content region in both mobile themes. The existing neutral surfaces, thin separators and read-only accounting presentation continue in these supplied views.

This is a scoped documentation check of the factual footer correction, supplementing the original 26 historical captures. The finish reviewer performs a separate targeted footer/regression recheck. No new review hunt, detector pass, durable token update or acceptance of the other later main UI changes is implied.
