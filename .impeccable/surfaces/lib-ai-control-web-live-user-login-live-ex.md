---
version: 1
slug: "lib-ai-control-web-live-user-login-live-ex"
primary_target: "lib/ai_control_web/live/user_login_live.ex"
related_targets: ["lib/ai_control_web/live/user_recovery_live.ex","lib/ai_control_web/live/user_settings_live.ex","lib/ai_control_web/live/platform_organizations_live.ex"]
---

# Authentication and organizer workspace

Visitor mode: Operate. Audience: the platform organizer now; account holders after invitation support.
Primary targets: login, recovery, account settings, and the organizer workspace.
English copy, real account identity, no invented activity or unavailable actions.

## Direction contract

THESIS: Establish a small, usable private workspace. Password sign-in leads; recovery stays a separate task. The organizer screen states its current capabilities honestly.
OWN-WORLD: User-pinned Linear/Vercel reference, code-first. Neutral light/dark surfaces, system sans, small rounded controls, restrained rules, semantic error/success colors. Theme follows the user's system unless explicitly selected.
STORY: Sign in, recognize the organizer role and available workspace, adjust account credentials, and sign out. Recovery uses one single-use link.
FIRST VIEWPORT: Authentication has a compact brand header and a centered 400px form. The workspace has a 232px rail, two real navigation entries, account identity below, and a spacious content region. Mobile folds navigation into the header.
FORM: User-pinned product interface references, no concept seed. The signature interaction is consistent, immediate appearance switching across every task without losing form state.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Verification

2026-10-03: login, recovery, settings, and organizer workspace captured at
1440×1000 and 390×844 in light and dark appearance. The independent finish review
requested three fixes: 44px mobile appearance controls, aligned checkbox/recovery
row, and compact desktop email overflow with full-address access. The verdict pass
scored all three resolved and returned `ship` for that fix list. All 16 recaptures
were valid. The manual detector and the automatic CSS hook reported no findings.
No raster assets ship in the interface. DESIGN.md and .impeccable/design.json
record the implementation after this verification.
