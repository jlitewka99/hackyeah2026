# Step 19 — human approval acceptance

Acceptance date: 2026-10-04. Implementation branch: `JL/step-19-human-approval`,
updated to `origin/main` at `8bcf703` before final regression checks. Local
application, database, real-model and release evidence is recorded below. Hosted
Linux container results belong to the PR checks; this report does not claim a
new Linux image was accepted locally.

## Accepted contract

Explicit policy v6 selectors require REVIEW for tools, Chat Completions,
buffered SSE and delegation. Pending requests have no downstream effect,
token reservation or retained execution slot. Approve permits one client
resume; it never performs the operation. Current controls, access, deadline
and budgets still apply. Dispatch accounting, approval consumption and required
audit commit atomically before the effect.

Pending and approved intervals are separately capped at 15 minutes and both
respect the continuing workflow deadline. Changed raw arguments or prepared
payload invalidate the binding. The latter includes redaction, generation
defaults, streaming, pinned model digest and RAG source revisions. A failed
claim is never returned to approved. Terminal/restarted workflows invalidate
unused approvals, and recovery never retries effects.

Preview storage uses operator-key AES-256-GCM with record/organization AAD.
All test data, encryption keys and administrator identities used for this
acceptance are synthetic. Plaintext never appears in audit/export/PubSub/list
metadata or Approval Inspect. Authorized detail rendering uses escaped text.

## Verification

The final regression gates passed on the updated main base, including the
overlapping-preparation fix.

| Check | Result |
| --- | --- |
| Targeted domain, policy, PostgreSQL concurrency, REST/MCP/chat/SSE/delegation and LiveView suite | 31 passed; one real-model test excluded and run separately |
| `mix precommit` | 723 ExUnit passed, 16 live tests excluded; five JS passed; format/compile/Credo/lockfile passed |
| `mix check.all` | Same regression counts; Dialyzer zero errors; Sobelow passed its configured medium threshold; dependency audit found no vulnerabilities |
| `run_security_tests.sh` | 723 ExUnit passed; Python: NER four passed/one live skipped, tokenizer nine, semantic eight, Prompt Guard nine; zero failed groups |
| Real pinned approval → resume → LLM → output controls | One test passed, 55.2 seconds, all configured guards enabled and required |
| `mix assets.build` | Passed, Tailwind 4.3.3 and esbuild 0.25.4 |
| Production assets and release build | Passed |
| Fresh database migrations and production health | Passed; `/health` 200 |
| Production approval release smoke with encryption configuration | Passed; authenticated binding, no effect before resume, one dispatch, ciphertext erased |
| Impeccable bounded desktop/mobile review in both themes | `ship`; no material fixes |

The focused suite includes initial/waiting retries, ownership and organization
isolation, raw/prepared argument conflicts, independent TTL boundaries, current
policy/approver access and request/token/workflow budgets, RAG revision and
completed-workflow refusal, startup uncertainty, missing encryption key, audit
creation/dispatch failure, and absence of payload in captured logs, persisted
audit, serialized exports and content-free notifications. SSE is verified over
actual HTTP using supervised Bandit fixtures: REVIEW is JSON before stream
headers, then one approved buffered stream completes. Provider fixtures in
these protocol tests are deterministic; the separate model test has no HTTP
stubs.

Four concurrency cases use separate PostgreSQL connections, a locked-row
barrier, process monitors and supervised test workers. They verify one dispatch,
one pending record for simultaneous initial attempts, expected-revision decision
conflicts, and overlapping preparations with changed raw input or changed
effective payload. The last case was added during final review: a second gate
must compare both fingerprints even if both attempts prepared before the first
approval was persisted.

LiveView tests use stable DOM IDs for authorized escaped preview, hidden
decision controls for readers, inline confirmation/focus events, approval with
no execution, filters/pagination, PubSub stream refresh, concurrent decisions
and revoked/unassigned access. Browser verification covers 1280×900 desktop
and 390×844 mobile viewports, list/detail/policy in both themes, approval
confirmation, an empty filtered list and keyboard focus. Some dynamic error,
expiry and rejection states use source/test evidence rather than separate
captures. The bounded [UI review](step19-ui-review.md) and
[design documentation](step19-design-documentation.md) describe those limits.

## Real-model and release conditions

The real-model test uses Ollama **0.35.1**, `qwen3.5:4b` digest
`2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd`,
the checksum-verified tokenizer, Polish NER v1 with the current v2-capable
service, and Qwen3Guard-Gen-0.6B revision
`fada3b2f655b89601929198343c94cd2f64d93cc`. Semantic inference uses the locked
PyTorch 2.8.0 / Transformers 4.57.1 CPU float32 runtime, two threads, on native
macOS arm64. All policy guards are enabled/required, including real NER,
semantic injection and output moderation; PII, secrets and signatures use the
actual deterministic implementations. The pending run has one logical call
and zero used/reserved tokens. Resume has positive actual token usage, settles
exactly that usage, consumes the approval and clears its ciphertext; reuse is
refused.

Earlier attempts failed closed before dispatch: the loaded local Docker
services timed out, a native attempt reached REVIEW but could not complete
tokenizer preflight, and a cold/swapped semantic model exceeded its 30-second
bound. No required guard, policy or application timeout was relaxed. Final
acceptance used the same pinned artifacts with native NER/tokenizer/semantic
services on isolated localhost ports and a warm semantic model. A separate
synthetic eight-field semantic request completed in 20.7 seconds under its
unchanged deadline. The successful 55.2-second end-to-end test is a warm-service
functional result, not a cold-start latency or capacity guarantee. Mandatory
control timeout remains a content-free refusal.

The native production release uses a fresh isolated PostgreSQL database,
independent synthetic audit/encryption keys and a private Erlang node.
`scripts/approval_release_smoke.exs` runs through release RPC with a
bootstrapped synthetic organizer and an in-memory sandbox. Its explicit
acceptance policy disables guards to isolate the release/encryption/dispatch
contract; real controls are qualified by the separate test above. No external
file, email or tool effect is performed. `docker/smoke` now runs this same
script with encryption configuration after bootstrap; the Dockerfile bundles
it. The live security runner includes the new model test.

## Operational limits

See [the operator/client runbook](../approvals.md) and Step 19 in the
[implementation plan](../../AI_CONTROL_LAYER_IMPLEMENTATION_PLAN.md).
Activation of policy v6 is required; old policy sources/checksums retain their
behavior. The preview key must be separate from audit and session keys.
Missing encryption configuration blocks REVIEW, and a malformed encoded key
prevents startup. There is one active key/ID, with no multi-key keyring.

Consumed authorization proves dispatch, not successful external execution or
client delivery. After an uncertain effect, inspect execution/workflow evidence
before creating a new operation. The workflow clock keeps running during human
review. Detector limitations and the outstanding Step 11 quality acceptance
remain applicable; REVIEW does not establish complete PII/injection detection.

Ciphertext is erased at consumption or terminal transitions. A delayed
maintenance job can delay physical expiry cleanup without extending validity.
LiveView memory and the authorized browser DOM transiently contain the preview;
WAL, replicas and backups can retain earlier ciphertext. Operators own backup
retention/encryption and key deletion. Pre-v6 migration rollback requires
planned treatment of REVIEW evidence and waiting receipts; forward fixes
preserve evidence.

The incumbent Impeccable documentation/sidecar drift and five inherited
typography advisories remain disclosed without a system redesign. Gated Prompt
Guard real-model acceptance and hosted Linux container qualification are not
claimed by the local Step 19 model run.
