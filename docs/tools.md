# Tool firewall core and sandbox (step 12A)

`AiControl.Tools.prepare/2` binds a tool request to a verified API-key
`AiControl.ApiKeys.Principal` and one immutable policy snapshot. The only accepted
request fields are `tool` and `arguments`; identity, policy, and schemas cannot be
supplied in the body. Requests are limited to 64 KiB of encoded JSON.
`ToolRequest` inspection excludes arguments, API-key IDs, and policy content.

The existing policy v2 `allowed_agents` and `tools.allowed_tools` lists authorize
operations. Missing tool permissions, policy v1, unknown tools, and unknown
argument fields deny access. No wildcard enables tools. A separate, immutable
operator grant for that sandbox and agent restricts exact resources; a policy
permission alone never enables a resource. This uses the existing v2 schema and
preserves historical policy checksums.

| Operation | Required arguments | Operator resource grant | Adapter |
| --- | --- | --- | --- |
| `file.read` | `path` | `paths` | Read a virtual file |
| `file.write` | `path`, `content` | `paths` | Create/replace a virtual file |
| `file.delete` | `path` | `paths` | Delete a virtual file |
| `http.get` | `url` | `endpoints` | Bounded GET with Req |
| `database.select` | `table`, `limit` (1–100) | `tables` | Select virtual rows |
| `email.send` | `recipient`, `subject`, `body` | `recipients` | Queue locally |
| `command.run` | `command`, `arguments` | `commands` | `status` or literal `echo` |

`AiControl.Tools.Catalog.all/0` exposes the JSON argument schemas. All properties
are required and additional properties are forbidden. String limits count Unicode
code points. `status` accepts no arguments; `echo` accepts one string and never
passes it to a shell. Database operations accept no SQL and cannot mutate data.
Email accepts one exact address and rejects recipient or subject header injection.

## Local demo

First create and activate a **new** policy v2 version through the existing policy
editor/YAML workflow, permitting e.g. `tools: {allowed_tools: [file.read]}` and the
agent. Obtain `principal` with `ApiKeys.authenticate/1`, using an active key for
that agent. From trusted local code:

```elixir
{:ok, sandbox} = AiControl.Tools.Sandbox.start_link(
  organization_id: principal.organization_id,
  grants: %{principal.agent_id => %{paths: ["documents/report.txt"]}},
  files: %{"documents/report.txt" => "Synthetic report"}
)

AiControl.Tools.Sandbox.run(sandbox, principal, %{
  "tool" => "file.read",
  "arguments" => %{"path" => "documents/report.txt"}
})
# {:ok, %{"content" => "Synthetic report"}}
```

Start each sandbox under a supervisor for a managed demo. Tests use
`start_supervised!/1`. The sandbox is bound to one organization; agents without
operator resource grants are denied. It revalidates the key, agent, organization,
policy integrity, and arguments immediately before invoking an adapter. A prepared
request retains its snapshot across policy activation, while revocation,
expiration, or suspension still stops execution.

Files, tables, mailbox messages, and commands are in-memory demo resources.
Paths must be relative and canonical: traversal, absolute/home paths, encoded
paths, backslashes, and symlink nodes on any ancestor or leaf are rejected.
Operator fixture symlinks are represented by `{:symlink, target}`. No adapter
reads or mutates the host filesystem, executes a shell, queries the application
database, or sends SMTP. State is temporary and cleared on process restart.
`Sandbox.inspect_state/1` is a trusted local demo aid containing synthetic data;
it must not be exposed through a public API.

## HTTP resources

For `http.get`, the agent's operator grant has this shape:

```elixir
%{
  endpoints: %{
    "http://demo.invalid:8080/report" => %{
      ip: {127, 0, 0, 1},
      allow_private?: true
    }
  }
}
```

The entire URL must match the entry, including scheme, host, port, and path.
Queries, fragments, credentials, ambiguous authorities, encoded paths, and zone
identifiers are rejected. A literal URL IP must match the pinned IP. The operator
chooses the destination IP; the request never resolves the supplied hostname.
Req connects to that IP while preserving the original Host and TLS hostname.
Redirects, retries, automatic decompression, and proxy configuration are disabled.
HTTP bodies are bounded at 64 KiB while receiving, must be valid UTF-8, and only
2xx bodies are returned. Other bodies/exceptions never enter the error result.
Connect, receive, pool, and request timeouts bound network work.

The conservative address classifier is based on the
[IANA IPv4 special-purpose registry](https://www.iana.org/assignments/iana-ipv4-special-registry/)
and [IANA IPv6 special-purpose registry](https://www.iana.org/assignments/iana-ipv6-special-registry/),
checked on 2026-10-04. It denies private, loopback, link-local, shared, documentation,
benchmark, multicast/reserved, and transition ranges. IPv6 requires the global
unicast block; IPv4-mapped IPv6 follows the IPv4 exclusions. Some special-purpose
anycast exceptions are conservatively denied. This is a local firewall policy,
not a guarantee of routability. A private demo service requires
`allow_private?: true` on its **exact** endpoint; callers cannot set this flag.

## Integration boundary and verification

There is no `POST /v1/tool_calls` endpoint or application-started sandbox in 12A.
Sandbox adapters are for trusted local demos and contract tests. **They do not
perform content filtering, budget accounting, or execution audit.** Step 12B must
wrap execution with tenant-scoped durable call counters, required input/semantic
guards, audit, and output filtering before making it available to clients.
After any argument redaction, revalidate the catalog and resource grants before
execution. Preserve the original request snapshot at all stages and recheck live
identity at the last point before effects. Host filesystem/SQL/shell adapters
would require a separate OS isolation design and are outside this demo.

```sh
mix test test/ai_control/tools
mix precommit
```

Tests cover successful operations and denials without effects, tenant/agent
substitution, policy changes, key revocation/expiration, suspension, schema and
Unicode bounds, traversal, symlinks, SSRF ranges, database operations, recipients,
commands, and real local HTTP pinning/redirect/body bounds. No external internet
service or real model is required for these tests. The full step 12 checkbox stays
open until the 12B integration acceptance.
