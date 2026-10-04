defmodule AiControl.PoliciesTest do
  use AiControl.DataCase, async: true

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures
  import AiControl.SecurityFixtures

  alias AiControl.{Agents, ApiKeys, Audit, Policies}
  alias AiControl.Policies.{Cache, Configuration}
  alias AiControl.Policy.{Engine, Snapshot}

  setup do
    scope = organization_fixture()
    %{scope: scope, agent: agent_fixture(scope)}
  end

  test "saving creates an immutable inactive version; activation and inheritance are explicit", %{
    scope: scope
  } do
    assert {:ok, initial} = Policies.current(scope)
    assert initial.inherited?
    assert initial.version.origin == "system"
    assert {:ok, version} = Policies.create_version(scope, Configuration.default())
    assert {:ok, unchanged} = Policies.current(scope)
    assert unchanged.version.id == initial.version.id
    assert {:ok, activated} = Policies.activate(scope, version.id, initial.set.revision)
    assert activated.version_id == version.id
    assert {:ok, own} = Policies.current(scope)
    refute own.inherited?
    assert own.version.id == version.id
    assert {:error, :stale_policy} = Policies.activate(scope, version.id, initial.set.revision)
    assert {:ok, _} = Policies.inherit(scope, own.set.revision)
    assert {:ok, inherited} = Policies.current(scope)
    assert inherited.inherited?
    assert {:ok, ^version} = Policies.get_version(scope, version.id)
  end

  test "new requests use new actions while held snapshots keep old decisions", %{
    scope: scope,
    agent: agent
  } do
    principal = principal(scope, agent)
    activate_default(scope)
    assert {:ok, old} = Policies.snapshot_for_request(principal, %{model: "deepseek-flash"})
    source = Configuration.default() |> Map.put("rules", %{"pii" => %{"action" => "block"}})
    assert {:ok, version} = Policies.create_version(scope, source)
    assert {:ok, current} = Policies.current(scope)
    assert {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    assert {:ok, new} = Policies.snapshot_for_request(principal, %{model: "deepseek-flash"})

    for {policy, action} <- [{old, :redact}, {new, :block}] do
      context = context_fixture(scope, policy)

      results =
        for guard <- Snapshot.required_guards(policy, :input),
            do:
              result_fixture(%{
                guard: guard,
                detections: if(guard == "pii", do: [detection_fixture()], else: [])
              })

      assessment = assessment_fixture(context, results)
      assert {:ok, decision} = Engine.evaluate(context, assessment, policy)
      assert decision.action == action
    end
  end

  test "invalid versions, tenant IDs and activation ownership cannot replace the active version",
       %{scope: scope} do
    other = organization_fixture()
    {:ok, version} = Policies.create_version(other, Configuration.default())
    {:ok, current} = Policies.current(scope)
    assert {:error, :not_found} = Policies.activate(scope, version.id, current.set.revision)
    assert {:error, :not_found} = Policies.get_version(scope, version.id)

    assert {:error, _} =
             Policies.create_version(
               scope,
               Map.put(Configuration.default(), "profile", "invalid")
             )

    assert {:error, _} =
             Policies.create_version(
               scope,
               Map.put(Configuration.default(), "allowed_agents", [agent_fixture(other).id])
             )

    assert {:ok, unchanged} = Policies.current(scope)
    assert unchanged.version.id == current.version.id
  end

  test "cache misses and stale entries cannot override the database pointer", %{
    scope: scope,
    agent: agent
  } do
    principal = principal(scope, agent)
    activate_default(scope)
    {:ok, old} = Policies.snapshot_for_request(principal, %{model: "deepseek-flash"})
    {:ok, current} = Policies.current(scope)

    {:ok, version} =
      Policies.create_version(scope, Map.put(Configuration.default(), "profile", "strict"))

    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    assert :ok = Cache.clear()
    {:ok, new} = Policies.snapshot_for_request(principal, %{model: "deepseek-flash"})
    refute new.checksum == old.checksum
    assert {:ok, new} == Cache.fetch(version.id)
    assert {:error, :invalid_security_data} = Cache.put(version.id, old)
    assert {:ok, new} == Cache.fetch(version.id)

    assert {:error, :invalid_security_data} =
             Snapshot.new(%{
               version: new.version,
               checksum: new.checksum,
               rules: new.rules,
               settings: Map.put(new.settings, "allowed_models", [])
             })
  end

  test "API principals are limited by policy, current credentials, organization and agent", %{
    scope: scope,
    agent: agent
  } do
    {_key, token} = key_fixture(scope, agent)
    {:ok, principal} = ApiKeys.authenticate(token)
    {:ok, current} = Policies.current(scope)
    source = Configuration.default() |> Map.put("agent_models", %{agent.id => []})
    {:ok, version} = Policies.create_version(scope, source)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)

    assert {:error, :model_not_allowed} =
             Policies.snapshot_for_request(principal, %{model: "deepseek-flash"})

    assert {:error, :forbidden} =
             Policies.snapshot_for_request(principal, %{
               agent_id: Ecto.UUID.generate(),
               model: "deepseek-flash"
             })

    assert {:ok, _} = Agents.set_status(scope, agent.id, :suspended)

    assert {:error, :forbidden} =
             Policies.snapshot_for_request(principal, %{model: "deepseek-flash"})
  end

  test "individual model grants use the operator model registry", %{
    scope: scope,
    agent: agent
  } do
    activate_default(scope)

    member =
      member_fixture(scope, :user, %{permissions: ["ai.use"], agents: [agent.id], models: ["*"]})

    assert {:ok, _snapshot} =
             Policies.snapshot_for_request(member.scope, %{
               agent_id: agent.id,
               model: "deepseek-flash"
             })
  end

  test "permissions are explicit and refreshed before mutations", %{scope: scope} do
    reader = member_fixture(scope, :admin, %{permissions: ["policies.read"]})
    assert {:ok, _} = Policies.current(reader.scope)
    assert {:error, :forbidden} = Policies.create_version(reader.scope, Configuration.default())
    assert {:error, :forbidden} = Policies.current(reader.scope, :global)

    assert {:ok, _} =
             AiControl.Organizations.update_member(scope, reader.membership.id, %{
               grants: %{permissions: []}
             })

    assert {:error, :forbidden} = Policies.current(reader.scope)
  end

  test "historical rollback retains creation metadata and records activation evidence", %{
    scope: scope
  } do
    {:ok, current} = Policies.current(scope)
    {:ok, first} = Policies.create_version(scope, Configuration.default())

    {:ok, second} =
      Policies.create_version(scope, Map.put(Configuration.default(), "profile", "strict"))

    assert {:error, :not_found} = Policies.rollback(scope, first.id, current.set.revision)
    {:ok, _} = Policies.activate(scope, first.id, current.set.revision)
    {:ok, next} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, second.id, next.set.revision)
    {:ok, next} = Policies.current(scope)
    assert {:ok, activation} = Policies.rollback(scope, first.id, next.set.revision)
    assert activation.operation == "rollback"
    assert {:ok, ^first} = Policies.get_version(scope, first.id)
    assert {:ok, events} = Audit.list_events(scope)
    event = Enum.find(events, &(&1.event_type == "policy.rolled_back"))
    assert event.data["before"]["policy_version_id"] == second.id
    assert event.data["after"]["policy_checksum"] == first.checksum
  end

  test "database rejects updates of version and activation records", %{scope: scope} do
    {:ok, version} = Policies.create_version(scope, Configuration.default())

    assert_raise Postgrex.Error, fn ->
      Repo.update!(Ecto.Changeset.change(version, configuration: %{}), mode: :savepoint)
    end

    assert {:ok, ^version} = Policies.get_version(scope, version.id)
  end

  defp principal(scope, agent) do
    {_key, token} = key_fixture(scope, agent)
    {:ok, principal} = ApiKeys.authenticate(token)
    principal
  end

  defp activate_default(scope) do
    {:ok, version} = Policies.create_version(scope, Configuration.default())
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
  end
end
