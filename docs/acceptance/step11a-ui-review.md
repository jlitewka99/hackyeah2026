# Step 11A UI finish review

Review date: 2026-10-04. Reviewer: shipped `impeccable_finish_reviewer` role, operating as a fresh subagent without a browser and without editing application files.

## Scope and evidence

The confirmed request covers a balanced Overview, Events with URL filters and keyset pages of 50, safe streaming JSONL export, read-only Budgets and Signatures, and related Agents/Policies summaries that preserve drafts. The interface must retain the incumbent English, neutral light/dark workspace with flat sections, responsive behavior, and keyboard access. Reporting remains tenant-scoped with refreshed independent grants; measured nearest-rank percentiles show samples, and historical gaps remain unrecorded. Full model comparison, MVP acceptance, and tool execution integration remain in Steps 11B/12B.

The review used `PRODUCT.md`, incumbent `DESIGN.md`, `.impeccable/surfaces/organization-reporting.md`, `.impeccable/config.json`, the shipped reviewer instructions and craft floor, the supplied detector result, and samples of the primary templates, reporting components, styles, LiveView updates, queries, export controller, and tests. It did not run a browser, detector, or test suite. Browser checks and test results supplied by the build thread are identified as reported evidence.

This is an ordinary code-led extension. The parent corroborated the applicable `reference/new-work.md` instruction to inherit the existing world and composition and resolve the addition directly, without a concept tournament. A concept seed, QUALITY BAR card, approved or decision comp, measured comp spec, and comp state are inapplicable. The user deferred pre-existing design-sidecar drift to a separate documentation task; this review does not approve or update that sidecar.

All 26 required captures were opened and checked in the initial review and opened again from the same paths in the verdict pass:

- `.impeccable/review/{overview,events,budgets,signatures,event-detail}-{desktop-light,desktop-dark,mobile-light,mobile-dark}.png` (20 files; the five routes, both themes, desktop and mobile).
- `.impeccable/review/agents-desktop-light.png` and `policies-desktop-light.png`.
- `.impeccable/review/overview-desktop-final-viewport.png` and `mobile-keyboard-navigation.png`.
- `.impeccable/review/events-empty-mobile-light.png` and `events-invalid-mobile-light.png`.

The required captures are valid: document tops, relevant route content, intended themes, sensible viewport dimensions, and no malformed blank or black regions. The synthetic organization is explicitly named **Synthetic demonstration**. Zero current-hour accounting follows the fixture's UTC rollover; it is not invented absence of activity.

## Initial review

Initial disposition: **fix**.

### persistence

Pass. PRODUCT.md and incumbent DESIGN.md exist; the code-led configuration and reporting contract preserve the established workspace. Comp and concept artifacts are inapplicable to this extension. All required captures exist and are valid.

### fidelity

| Element or promise | Verdict | Evidence |
| --- | --- | --- |
| TYPE | Match | Compact system sans; identifiers and JSON use monospace for actual data. |
| MATERIAL | Match | Flat interface surfaces, thin rules, bundled icons; no imitation physical material. |
| GROUND | Match | Captures retain the incumbent white and neutral graphite fields; CSS uses DESIGN.md's theme tokens. |
| THESIS | Match | Activity, measured latency, current budget, controls, and request evidence establish the intended connections. |
| OWN-WORLD | Match | English copy, neutral controls, restrained semantic colors, and existing navigation. |
| STORY | Match | Overview summaries lead to filters, event detail, export, budgets, signatures, and policy configuration. |
| FIRST VIEWPORT | Match | Desktop shows scope, range, balanced activity and budget; mobile retains the header and stacks content. |
| FORM | Match | URL-backed filters and coalesced reporting updates are present; sampled Agents refresh preserves its edit form. |
| Responsive navigation | Adaptation | Native disclosure preserves destinations and visibly focused keyboard access, as required by FIRST VIEWPORT. |
| Latency table semantics | Contradicted | Each data row has a row header and p95/Samples cells, but its p50 span lacks `role="cell"` despite four declared column headers. |
| Truth | Match | Synthetic organization is labeled; measurements have units and sample counts; current-hour zero usage, absent observations, and unconnected tool execution are stated explicitly. |

### ceiling

Reached for the incumbent workspace: precise spacing, flat sections, consistent theme geometry, responsive evidence rows, and visible focus. The supplied detector contains five typography advisories and no primary findings; the advisories do not establish a material visual defect in the captures. No second detector pass was run by this reviewer.

### material_fixes

1. Floor/accessibility: add `role="cell"` to the p50 value span in `lib/ai_control_web/live/organization_overview_live.html.heex` so every measured-latency row exposes all four columns consistently to assistive technology.

### keep

Preserve the balanced activity/budget hierarchy, neutral theme tokens, explicit evidence limitations, permission-aware links, and draft-preserving updates.

## Verdict pass

This pass scores only the sole material fix from the initial review and checks for regressions introduced by that fix. It is not a new full-surface review or a new issue hunt. The build thread recaptured the same 26 paths after the fix; this reviewer reopened every file. The source was read to verify the semantic change, which still images cannot expose.

### verdict

1. **Resolved:** the p50 span now has `role="cell"` in `lib/ai_control_web/live/organization_overview_live.html.heex:97`, alongside the p95 and Samples cells and the measurement row header. The recaptured Overview retains the same visible four-column layout in both themes and viewport classes. The build thread additionally reported that the browser accessibility snapshot exposes each sample as one row header and three cells. No fix-induced visual regressions were observed in the supplied recaptures.

The build thread reported `mix precommit` passing with 476 tests passed and 7 excluded, three JavaScript tests passing, and the assets build passing after the fix. Those checks were not independently rerun by this reviewer.

### remaining

Clear. The verdict-pass ship covers the scored fix, not a new full-surface review.

Final disposition: **ship**.
