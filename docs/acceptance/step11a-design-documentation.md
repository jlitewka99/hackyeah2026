# Step 11A design documentation

Checked 2026-10-04 using the shipped `impeccable_documenter` workflow for an ordinary extension. This pass records evidence from current source and supplied captures. It did not operate a browser, rerun the detector, run application tests, or refresh the design tokens.

## Checked evidence

Read `PRODUCT.md`, incumbent `DESIGN.md`, `.impeccable/config.json`, `.impeccable/design.json`, the reporting direction contract, and the shipped documentation reference. Source sampling covered `assets/css/app.css`, the workspace layout, all five reporting HEEx templates and their paired LiveView modules, `ReportingHTML`, and `ReportingLive`.

All 26 capture files were opened. Each showed its expected route or supplemental state and theme. The five-route matrix contains all four desktop/mobile and light/dark combinations:

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

The [finish reviewer record](step11a-ui-review.md) contains the initial full review and its single material finding: the p50 span lacked a cell role. Current Overview source includes `role="cell"`. The final **ship** disposition is scoped to scoring that fix and checking its regressions; it does not announce a new full-surface review. Browser behavior and test results in that record remain build-thread-reported evidence.

The supplied `/private/tmp/step11-impeccable-detect.json` contains five typography advisories and no primary findings. Its values include the reporting summary size and mobile latency size alongside other workspace styles. This evidence pass neither canonizes those advisory values into the design system nor repairs them.

No new visual world or approved durable system change was established. `DESIGN.md`, `.impeccable/design.json`, `PRODUCT.md` and `.impeccable/config.json` were left unchanged; application source, implementation plan and reviewer record were not edited by this documenter. The known pre-existing sidecar drift remains deferred to the user's separate `impeccable document` task. Documentation of the extension stays local to this report and the reporting surface brief.

These synthetic captures establish the checked UI states and system continuity. They do not measure real-model performance or complete MVP acceptance and tool execution integration in Steps 11B/12B.
