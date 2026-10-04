# Step 14 design documentation

Checked on 2026-10-04 with the shipped `impeccable_documenter` workflow. Selective Granite Guardian is an ordinary Operate extension of Policies and Event details. This preservation-only pass records the finished interface; it establishes no new visual world or durable system change.

## Checked evidence

Read the shipped documenter role, `reference/document.md`, `PRODUCT.md`, `DESIGN.md`, the sidecar narrative/component coverage, and the Policies and Reporting surface briefs. Source comparison covered `assets/css/app.css`, `policy_html.ex`, `policy_html/panel.html.heex`, the shared `granite_editor.html.heex` and `granite_settings.html.heex` component templates, `policy_live.ex`, and `organization_event_live.ex` with its separate `.html.heex` template. The schema-v6 defaults and built-in criteria were sampled to verify the meaning of the fields, rather than infer policy behavior from labels alone.

Six existing captures were reopened: `desktop-light.png`, `mobile-dark.png`, `desktop-light-detail.png`, `mobile-light-detail.png`, `events-desktop-dark.png`, and `events-mobile-light.png`, all under `.impeccable/review/step14/`. The full policy views preserve flat sections and the existing navigation; the detail view shows the visible keyboard focus ring on Check suspicious input. Event details preserve the historical policy identity and explain each check above the safe evidence region. The mobile Event view wraps criterion hashes and retains the complete score, polarity, skipped-check and failure explanations.

File metadata was checked for all ten captures. The `.png` filenames contain JPEG image data; the files open correctly and were preserved without renaming or conversion. The full-page image heights below exceed the reported 1440×1000 and 390×844 capture viewports.

| Evidence | Files in `.impeccable/review/step14/` | Image size |
| --- | --- | --- |
| Policy editor, both themes | `desktop-{light,dark}.png` | 1440×7050 |
| Policy editor, both themes | `mobile-{light,dark}.png` | 390×8577 |
| Policy detail viewports | `desktop-light-detail.png`, `mobile-light-detail.png` | 1440×1000; 390×844 |
| Event details, both themes | `events-desktop-{light,dark}.png` | 1440×1715 |
| Event details, both themes | `events-mobile-{light,dark}.png` | 390×2268 |

These captures use synthetic preview fixtures. They demonstrate interface states and do not qualify Granite model accuracy, live availability, latency or enforcement. The supplied build checks report no horizontal overflow at 1440px or 390px and keyboard Tab reaching the trigger checkbox with visible focus. The single supplied detector run returned `[]`. This documentation pass did not operate a browser, rerun the detector, alter captures, or run application/model tests.

## Incumbent system comparison

- **Palette:** existing neutral surface, subtle surface, ink and rule properties remain the material of Policies and Events in both themes. The CSS light/dark values match the incumbent frontmatter. Focus and feedback keep their semantic roles; the extension adds no decorative accent.
- **Typography:** the compact system sans hierarchy remains: page heading 1.75rem, section heading 1.0625rem, body 0.9375rem, controls 0.875rem and field labels 0.8125rem. Historical identifiers retain the existing technical treatment. No new type role or one-off value was promoted into the design system.
- **Layout and depth:** the 14.5rem desktop rail, 56rem content cap, shared main padding, thin rules and flat task regions remain. Shared policy and evidence rows stack at their existing mobile breakpoints; long criterion IDs, selectors and hashes can wrap. Granite adds no surface shadow or new container vocabulary.
- **Controls and access:** shared `.ex`/`.html.heex` components use the imported `<.input>` for labeled native fields, selects, checkboxes and textareas. Stable IDs, the existing primary/secondary controls, global visible focus, 180ms state transitions and reduced-motion override remain. Still images establish visible states, not motion execution.
- **Named rules:** Semantic State, Same Task and Flat Task continue to apply, with the established compact hierarchy underlying Single Family. Task-specific judging criteria and selection behavior remain local policy concepts rather than new visual-system rules.

## Finished interaction and review scope

Schema-v6 upgrade is an explicit draft action; Granite is disabled by default. The editor exposes enablement, suspicious-input selection and its Prompt Guard threshold, high risk catalog operations, and exact privileged-resource selectors. The guidance explains that selectors add checks and do not grant access. Three editable built-in criteria cover suspicious input, tool alignment and groundedness. Custom criteria expose ID, task, text and an explicit `block_on` choice: Yes means the criterion is met; No means it is not met. The adjacent explanation states which result blocks. Groundedness is limited to responses using retrieved sources.

The active-settings component renders the actual saved enablement, threshold, operations, resource selectors, criterion text/task and blocking polarity. Shared comparison helpers identify Granite differences. The existing inspect → draft → save → compare → activate flow remains deliberate; saving prepares an immutable version and leaves activation as a separate action. YAML and streamed history remain part of the incumbent workflow. Source establishes those settings/comparison paths; the supplied viewport details are not a separate capture of every expanded settings or comparison state.

Event details derive Granite status and streamed check rows from serialized historical audit evidence. They show the trigger, criterion hash, score, recorded blocking polarity and decision, and distinguish an unselected/not-applicable check from an unavailable selected check. The synthetic fixture shows a tool-alignment `no` score blocking under `block_on=no`, groundedness skipped because there are no retrieved sources, and a selected check failure blocking the request. Historical results are described using the recorded criterion and model digest rather than the current active settings.

The [finish review record](step14-ui-review.md) records **ship** with persistence, fidelity and ceiling passing against the retained incumbent bar and no material fixes. The reviewer accepted the responsive adaptation at 390px and the supplied keyboard/overflow checks. This disposition covers the Step 14 UI extension and synthetic evidence states; it does not establish model qualification or acceptance of unrelated surfaces.

## Preserved context and deferred drift

`PRODUCT.md` retains historical starter/open-decision wording. `DESIGN.md` and the sidecar still describe reporting and policy tools as unbuilt, and the sidecar navigation preview has older coverage. Existing technical monospace and disabled-input patterns also exceed the early system prose. This pre-existing documentation drift remains recorded without repair or canonization; the user explicitly deferred the sidecar refresh to a separate `impeccable document` task.

No new craft defect was identified in the documentation sample. Only this report, the Step 14 UI review handoff record and the narrowly scoped Policies/Reporting brief entries were written. Application code, `PRODUCT.md`, `DESIGN.md`, `.impeccable/design.json`, configuration and unrelated briefs were preserved.
