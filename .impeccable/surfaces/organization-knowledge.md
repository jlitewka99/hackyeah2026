---
version: 1
slug: organization-knowledge
primary_target: lib/ai_control_web/live/organization_knowledge_live.ex
related_targets: [lib/ai_control_web/live/organization_knowledge_live.html.heex, lib/ai_control_web/components/policy_html/panel.html.heex]
---

# Knowledge · Step 18

Mode: Operate. Ordinary extension of the existing workspace; code-led, no approved comp.

THESIS: Let managers inspect and explicitly maintain checked sources while keeping agent memory private unless shared for reading.
OWN-WORLD: Preserve neutral light/dark tokens, compact system typography, thin borders, flat sections, existing workspace navigation and responsive row stacking. No new design system or imagery.
STORY: Documents and Memory tabs lead to checked-text search and owner filtering, then source detail and a separate editor. Creating and saving explicitly requests scanning. Names identify owners and sharing recipients. Blocked detail shows a safe explanation and authorized deletion without showing unchecked text.
FIRST VIEWPORT: Heading, concise guidance, source tabs and primary add action precede filters and resource rows. Mobile preserves all controls in a single column.
FORM: Existing controls and labels, stable DOM IDs, visible keyboard focus, native form semantics and restrained transitions. The signature interaction is an explicit Check and save action with pending scan feedback; source provenance and prior storage decision remain visible separately from checked text.
FINISH: Desktop 1440×1000 and mobile 390×844, both themes, covering list, detail and editor, plus empty/search failure. Finish reviewer receives all captured paths; documenter preserves DESIGN.md and its pre-existing stale sidecar. Initial disposable preview fixtures disabled guards; the special blocked-read fixture enabled the built-in PII guard. Synthetic captures do not qualify real-model enforcement.

## Finished evidence · 2026-10-04

The finished Knowledge surface retains the incumbent semantic light/dark palette, compact heading and control sizes, thin rules, flat task sections, small rounded controls, and shared workspace shell. Heading, guidance, Documents/Memory tabs and the permitted add action precede checked-text search and owner filtering. The filter grid and resource rows stack on mobile; checked body text wraps inside a separate bordered region. No new raster assets, comp, visual world or durable system change were introduced.

The paired LiveView and HEEx files keep source detail separate from the editor. Owner and read-only recipient names identify access, while provenance, trust/revision, the earlier storage check and stored policy precede the currently checked body. Creation and editing use labeled native controls and an explicit Check and save action; source shows its disabled pending label and form busy state. Blocked detail withholds text and the editor, explains the unavailable body, and offers deletion only when manageable?. The new upload control preserves its native filename display and stable ID while using the incumbent bordered button treatment at a minimum 44px height.

Schema v5 policy additions reuse the existing ruled form. Retrieval and explicit memory writes have separate labels and guidance; allowed source kinds, trust levels and the pinned NER rule set remain native labeled controls. Named entity weights are labeled separately from the NER rule set. This records the added controls, not acceptance of the full policy workflow.

The capture packet contains 25 files at `.impeccable/review/step18-*.png`: list/detail/edit/new in both device widths and themes, three mobile supplemental states, two blocked-source captures and four policy captures. Full-page image heights vary with content; reported viewports are 1440×1000 and 390×844. The [finish review](../../docs/acceptance/step18-ui-review.md) returns **ship** for the two scored fixes and the limited supplemental Knowledge/NER controls. The original 19-capture review remains historical evidence; the final verdict does not reopen the entire surface or qualify security-model behavior.

The [documentation evidence](../../docs/acceptance/step18-design-documentation.md) records source comparison, the six captures reopened in this documentation pass, and preserved drift. `DESIGN.md` and `.impeccable/design.json` remain unchanged. Their earlier implementation scope and preview coverage are not expanded into new normative tokens or rules by this extension.
