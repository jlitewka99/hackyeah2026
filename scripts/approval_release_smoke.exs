# Trusted operator smoke task. All operations use a synthetic, in-memory sandbox.
alias AiControl.{
  Accounts,
  Agents,
  ApiKeys,
  Approvals,
  Organizations,
  Policies,
  Repo,
  Tools,
  Workflows
}

alias AiControl.Approvals.{Approval, Cipher}
alias AiControl.Policies.Configuration
alias AiControl.Tools.{Config, Sandbox}
alias AiControl.Workflows.Run

{:ok, key, _} = Cipher.key()
32 = byte_size(key)
user = Accounts.get_user_by_email(System.fetch_env!("AI_CONTROL_ORGANIZER_EMAIL"))

{:ok, org} =
  Organizations.create_organization(Accounts.Scope.for_user(user), %{
    name: "Synthetic approval release #{Ecto.UUID.generate()}"
  })

{:ok, scope} = Organizations.fetch_scope(Accounts.Scope.for_user(user), org.id)
{:ok, agent} = Agents.create_agent(scope, %{name: "Synthetic approval agent"})
{:ok, {_key, token}} = ApiKeys.create_key(scope, agent.id, %{label: "Release smoke"})
{:ok, principal} = ApiKeys.authenticate(token)

source =
  Configuration.default(6)
  |> Map.put(
    "guards",
    Map.new(Configuration.guards(6), &{&1, %{"enabled" => false, "required" => false}})
  )
  |> Map.put("tools", %{"allowed_tools" => ["file.write"]})
  |> Map.put("review", %{
    "enabled" => true,
    "tools" => ["file.write"],
    "llm_models" => [],
    "delegation_agents" => []
  })
  |> Map.put("budgets", %{"workflow" => %{"max_duration_seconds" => 3600}})

{:ok, version} = Policies.create_version(scope, source)
{:ok, current} = Policies.current(scope)
{:ok, _} = Policies.activate(scope, version.id, current.set.revision)

{:ok, server} =
  Supervisor.start_child(
    AiControl.Tools.Supervisor,
    Supervisor.child_spec(
      {Sandbox,
       [
         name: Config.via(org.id),
         organization_id: org.id,
         grants: %{agent.id => %{paths: ["smoke.txt"]}}
       ]}, id: org.id)
  )

{:ok, {run, participant}} =
  Workflows.create(
    principal,
    %{"goal" => "Synthetic release approval acceptance"},
    Ecto.UUID.generate()
  )

params = %{
  "tool" => "file.write",
  "arguments" => %{"path" => "smoke.txt", "content" => "Synthetic release approval payload"}
}

opts = [
  idempotency_key: Ecto.UUID.generate(),
  run_context: %{run_id: run.id, participant_id: participant.id}
]

{:error, {:approval_required, %{approval_id: id}}} = Tools.execute(principal, params, opts)
record = Repo.get!(Approval, id)
{:ok, ^params} = Cipher.decrypt(record)
{:error, :approval_unavailable} = Cipher.decrypt(%{record | id: Ecto.UUID.generate()})
false = Map.has_key?(Sandbox.inspect_state(server).files, "smoke.txt")
%{calls: 1, reserved_tokens: 0} = Repo.get!(Run, run.id)
{:ok, _} = Approvals.decide(scope, id, :approve, record.revision)
false = Map.has_key?(Sandbox.inspect_state(server).files, "smoke.txt")
{:ok, _} = Tools.execute(principal, params, Keyword.put(opts, :approval_id, id))
%{status: "consumed", ciphertext: nil} = Repo.get!(Approval, id)
"Synthetic release approval payload" = Sandbox.inspect_state(server).files["smoke.txt"]
{:error, :approval_used} = Tools.execute(principal, params, Keyword.put(opts, :approval_id, id))
%{calls: 1} = Repo.get!(Run, run.id)
%{tool_calls: 1} = Workflows.evidence(Repo.get!(Run, run.id))
{:ok, _} = Workflows.transition(principal, run.id, "complete")
:ok = Supervisor.terminate_child(AiControl.Tools.Supervisor, org.id)

IO.puts(
  "Approval release smoke passed: AES-256-GCM binding, no effect before resume, one dispatch, ciphertext erased"
)
