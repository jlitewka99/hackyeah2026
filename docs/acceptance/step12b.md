# Step 12B acceptance

Accepted locally on 2026-10-04 on `JL/step-12b-tool-execution`. Step 12 now
integrates the existing sandbox operations with the input/output firewall,
durable idempotency, call accounting and mandatory audit. Dashboard/Events and
final MVP model qualification remain in Step 11; full workflows remain in 15.
All test data and local network services are synthetic.

## Verification

The initially missing Mix dependencies were restored from the existing lockfile;
no dependency or lockfile changes were needed. PostgreSQL tests use the isolated
`MIX_TEST_PARTITION=step12b` database; browser fixtures use `step12bqa`.

| Check | Result |
| --- | --- |
| `MIX_TEST_PARTITION=step12b mix precommit` | 495 ExUnit tests pass, nine opt-in tests excluded; three JavaScript tests pass; formatting, strict compilation, lockfile check and Credo pass |
| `MIX_ENV=test mix assets.build` | Tailwind and esbuild pass |
| `mix dialyzer` | Zero errors |
| `mix security` | Sobelow configured gate passes; dependency audit reports no vulnerabilities |
| Tool `:live_models` tests | Two real NER/Qwen tests pass, final run 25.6 seconds |
| Shared gateway real-model regression | Four real NER/semantic tests pass, 37.7 seconds |
| `git diff --check` | Pass |

Sobelow retains the existing low-confidence `File.read!` upload-path finding in
`PolicyLive.upload_text/1`, which reads a Phoenix-managed upload. No new finding
was introduced. These are local checks; this document does not claim CI or
production throughput results.

The first CI Quality job found one migration formatting difference omitted by
the local formatter cache. The migration is corrected; `check` and `precommit`
now force full formatting passes. A fresh formatter check and repeated precommit
pass with the same 495 ExUnit and three JavaScript results. No runtime logic changes.

## API, guards and effects

Endpoint tests exercise authentication before parsing, IP/organization/agent
admission, UUID idempotency headers, malformed and oversized JSON, extra identity
fields, context-limit errors and private duplicate responses. Only `{tool,
arguments}` is accepted. Success exposes a filtered result plus generated request
and execution IDs. Fixed errors and `no-store` responses exclude raw adapter data.

The seven catalog operations pass through the domain entry point. The original
12A attack tests remain passing, with integrated traversal, SSH-path, symlink,
SSRF, SQL/table, recipient and command denials before effects. Input and output
tests cover deterministic rules, required unavailable guards, Unicode byte
offsets, immutable selectors/keys, invalid offsets, nested rows, redaction,
invalid UTF-8 and the 64 KiB result bound. Moderation receives redacted accepted
input; semantic stages follow the captured policy. Existing Chat Completions
tests pass with the default content adapter.

Coordinated tests activate a different policy during semantic assessment and
confirm one immutable snapshot. Revoking the API key, agent, organization or
operator resource during assessment prevents dispatch. Actual local HTTP and
HTTPS exercise the firewall, accounting, no retry, pinned IP, CA and hostname
verification; untrusted CA is denied. Original transport tests retain redirect,
body-size, ambient-credentials and hostname-denial coverage.

Real Presidio/Stanza PL/NKJP tests redact Polish names, addresses and PESEL in
Unicode arguments and nested results. Pinned Qwen tests compare direct assessment
with the firewall on identical projected fields for a safe Polish control and an
injection attempt, without retuning thresholds. Shared gateway real-model tests
also cover output redaction and semantic response blocking. These tests establish
integration, not improved model quality; the Step 10 benchmark limits still apply.

## Durability and failure boundaries

Eight concurrent submissions of one key produce one dispatch. Reusing it across
API-key or operator-context changes returns only the stored ID/state; changed
arguments produce a distinct conflict. Receipts contain HMAC fingerprints and
snapshots, without arguments or results. Tenant isolation, historical policy
checksums and budget lock ordering remain covered.

Tests cover null/zero limits, lowering a limit, activation without resetting
usage, abandoned pending/dispatching recovery and expiry/cancellation before
effects. An actual delayed HTTP request times out after dispatch: the receipt
becomes charged `uncertain`, and retry does not contact the server again.
Output blocking and adapter failure remain charged. Forced input-audit and
dispatch-audit failures prevent effects and roll back accounting; terminal-audit
failure withholds the result and leaves the receipt for recovery. Audit validation
rejects arbitrary content, inconsistent states and charge flags.

## Frontend evidence

The shared organization/platform policy panel retains its English incumbent
appearance. Seven described native checkboxes use the draft adapter without
changing `tools.allowed_tools` or v1/v2/v3 checksums. Unknown imported IDs remain
visible as unsupported until deliberately removed. Effective settings and
before-activation differences show the permissions; the form explains operator
grants and the persistent context limit, null and zero.

Four tool-specific LiveView tests pass alongside existing policy tests, covering
selection, save/activate/export, clearing permissions, unsupported-ID retention
and removal, historical immutability, read-only access and the global panel.
Browser checks cover save/review, recoverable YAML errors, Space/Tab and associated
descriptions. Layout checks find no horizontal overflow at 1440, 1280 and 390px;
checkbox labels provide 44px targets with visible focus.

Ten local captures under `.impeccable/review/step12b-*.png` cover both themes,
desktop/mobile, both panels, focused tools, saved differences and YAML recovery.
One automatic Impeccable detector pass has no deterministic findings. The fresh
finish reviewer returns **ship**, with no material fixes. The review explicitly
names the unavailable separate Operate QUALITY BAR card and assesses the
user-confirmed incumbent extension against its supplied quality bar.
Documentation comparison records the extension in the policy surface brief;
PRODUCT.md, DESIGN.md and the explicitly deferred stale sidecar are preserved.

## Migration, configuration and limitations

Run `mix ecto.migrate` for `20261003233603_create_tool_executions`. Set the
server-owned `TOOLS_SANDBOXES` organization/agent grants and stable UUID contexts
as described in [tools.md](../tools.md). No assignment denies execution. Required
guard services must be healthy. The [demo policy](../tools-demo-policy.yaml)
enables semantic input/output and response moderation. Default tool admission is
one slot with a 10-second execution deadline and no automatic retry.

Recovery assumes the roadmap's single application instance. Multi-node recovery
ownership and distributed admission are outside this demo. Durable claims prevent
redispatch, but external effects have no exactly-once guarantee. Resolve an
uncertain outcome before deliberately using a new key. Results are not replayed;
virtual sandbox data and local mailbox reset on restart. Output blocking or
terminal-audit failure cannot undo an effect. Host filesystem, SQL, shell and SMTP
are not exposed. Qwen's limited injection recall and long-input deadline errors
remain documented in [Step 10](step10.md); final model qualification stays in 11B.

Step 12's checkbox is checked after this local acceptance. Step 11 remains open.
