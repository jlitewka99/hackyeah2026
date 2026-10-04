# Step 16 design documentation

Documentation date: 2026-10-04. This is an ordinary Operate-mode extension of the existing organization workspace. The user-specified scope and [direction contract](../../.impeccable/surfaces/background-jobs-tests.md) establish the launch → history → safe evidence flow. No comp, quality card or new visual world applies.

## Scope and incumbent comparison

The extension covers Tests launch/history, test-run details, Reports generation/history, Events background export, Signatures operator-package refresh/imported candidates and the schema-v5 policy candidate selector. It follows PRODUCT.md's English terminology and evidence honesty: tests are labeled “Synthetic test data”; status/counters are shown without interaction content, model qualification or invented measurements.

Compared with DESIGN.md and existing CSS, these surfaces retain the semantic light/dark palette, compact system sans headings/body, thin rules, flat task regions, existing rounded primary/secondary controls and native labeled inputs. Reports and Tests join the permission-aware rail/mobile navigation with the existing current-page semantics. Candidate identifiers and checksums reuse the incumbent wrapping monospace treatment.

The new reusable background row separates identity, UTC time, mode/range, evidence and error copy from status/progress and permitted actions. Desktop rows place actions beside content; at 640px and below rows/forms stack and actions align left. Existing report facts stack at the incumbent mobile breakpoint. The new CSS adds no palette or typography primitives, surface shadows or raster assets.

Pre-existing documentation drift remains: DESIGN.md and the sidecar describe an earlier, narrower workspace, while reporting, resource identifiers and policy patterns already exist in CSS. The single detector output at `/private/tmp/step16-design-detect.json` contains five advisory font-ramp findings at incumbent CSS lines 120, 143, 149, 166 and 236 (1.125rem, .75rem, .75rem, 1rem, 1rem). Those declarations precede the extension. `.impeccable/design.json` is already stale; an explicit `impeccable document` refresh remains a separate task. PRODUCT.md, DESIGN.md, the sidecar and other surface briefs were preserved.

## Reusable state semantics

- Submission uses task-specific “Queuing…” feedback; active permitted rows expose “Cancel” and “Cancelling…”. Streams refresh histories and scenario evidence independently of launch-form values.
- Completed, unexpired artifacts expose Download; failed/cancelled runs do not publish a partial download. Expired results retain explicit history/retention copy.
- Run errors use the existing danger color and concrete recovery guidance. Pending scenarios, cancelled zero-result runs, other terminal zero-result runs and expired scenarios have distinct copy.
- Report copy states the fixed UTC range and current-hour budget snapshot. Events background export follows the current selection into Reports history. Imported signature candidates remain separate from the active policy; v5 selection, saving and activation are deliberate existing policy steps.
- Templates retain associated visible input labels, stable IDs, named sections, current navigation semantics and source-defined visible focus/reduced-motion behavior. The mobile keyboard capture shows a focus outline. Screen-reader behavior was not observed.

## Evidence checked and review scope

Checked source: the five `organization_{tests,test_run,reports,events,signatures}_live.ex`/`.html.heex` pairs, `background_html.ex`, `policy_html/panel.html.heex`, `layouts.ex` and `assets/css/app.css`. PRODUCT.md, DESIGN.md, the full direction contract, the document workflow and the existing detector output were read; no additional context or detector run was performed.

Local ignored JPEG evidence is under `.impeccable/review/`:

| Evidence | Scope |
| --- | --- |
| `step16-capture-manifest.json` | Tests, detail, Reports, Signatures and Events: 20 theme/viewport captures |
| `step16-policy-capture-manifest.json` | Policy v5 candidate selection: four theme/viewport captures |
| `step16-fix-capture-manifest.json` | Tests, detail and zero-result cancellation: 12 recaptures |

All three manifests record document width equal to viewport width: desktop 1440×1000 and mobile 390×844. Full-page image heights can be taller. Representative images inspected directly for this handoff: Tests desktop light, completed detail desktop light/mobile dark, Reports mobile light, Signatures desktop dark, Events mobile dark, policy mobile light/dark, cancelled detail mobile light, failed-empty detail mobile dark and mobile keyboard dark. Additional empty/unavailable/cancelled captures are supplemental evidence, not a claim of exhaustive accessibility testing.

The independent reviewer first examined the full valid 24-capture matrix and identified two material fixes: semantic danger color for errors and explicit terminal zero-result copy. One correction batch was recaptured; the same reviewer scored both fixes resolved with disposition **ship**. That verdict covers the listed fixes and does not constitute a renewed whole-surface “no material issues” approval.

[Operational acceptance](step16.md) records 648 passing tests with 13 excluded local-model cases after integration with current main and a production release Controlled result of 15/15. Missing-model Live gateway execution failed while retaining 15 Controlled cases; standalone Live semantic execution failed with zero cases and recovery guidance. Successful full Live acceptance remains unverified. These limits do not alter the synthetic-data labeling or turn failure into success.

Earlier documentation recheck: integration with main at `e072dd0` preserved the reviewed Step 16 LiveViews/templates, shared background component, policy panel, layout and CSS; their diff against the reviewed implementation was empty. The supervisor merge retained both Oban and MCP sessions. That recheck added no visual review or detector pass.

Final later-edit recheck: current main `6366bd9` adds incumbent Knowledge navigation/CSS and combines both schema-v5 policy control sets. The merged panel preserves Knowledge/memory switches, source/trust controls and the pinned NER rule selector alongside Step 16's imported-signature selector. Upgrade copy covers both, and the NER weights label keeps its stable ID and wrapping. The imported set remains a draft choice until saving and deliberate activation. PRODUCT.md, DESIGN.md, the stale sidecar and other briefs remain unchanged; no context or detector was rerun.

Checked the merged panel source, layout/CSS diff and integration test assertions. The backend regression covers imported-signature activation/request snapshot plus Knowledge switches and `pl-nkjp.v1` through a Draft roundtrip; the LiveView test asserts both control sets and the default `pl-nkjp.v2` rule selection. Directly inspected `step16-step18-policy-desktop-light.jpg` and `step16-step18-policy-mobile-dark.jpg`. The four-capture `step16-step18-policy-manifest.json` records desktop 1440×1000/mobile 390×844 in both themes, document widths 1440/390, Knowledge control presence, the imported set and selected `pl-nkjp.v2`; full-page image heights may exceed the viewport.

The same independent reviewer returned **ship** for the merged policy controls across those four valid captures, finding fidelity/persistence preserved and requesting no fixes. This scoped review supplements the earlier verdict on the two Step 16 fixes; it does not reopen or approve unrelated surfaces.

Final merged `mix precommit` passed with the dedicated runner database (648 passed, 13 excluded); production release Controlled execution remains 15/15. Linux CI on earlier commit `518a14b` failed with `epipe`. The runner now unlinks/monitors the port, consumes pending result lines before an idle heartbeat and closes safely; the regression passes locally. On 2026-10-04, [Linux CI run 37176464160](https://github.com/jlitewka99/hackyeah2026/actions/runs/37176464160) succeeded on code commit `83d2cb7`: Quality, Tests, Dialyzer, Security and the Phoenix/NER/Qwen/tokenizer container job passed. Gated Prompt Guard was skipped. Successful full Live acceptance remains unverified, so the draft PR and plan checkbox stay open. This operational evidence update does not change the scoped UI review verdicts.
