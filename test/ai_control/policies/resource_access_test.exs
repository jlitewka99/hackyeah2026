defmodule AiControl.Policies.ResourceAccessTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.{Organizations, Policies}
  alias AiControl.Policies.Configuration

  setup do
    previous = Application.get_env(:ai_control, :organization_resource_resolver)

    Application.put_env(
      :ai_control,
      :organization_resource_resolver,
      AiControl.TestPolicyResourceResolver
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ai_control, :organization_resource_resolver, previous),
        else: Application.delete_env(:ai_control, :organization_resource_resolver)
    end)

    scope = organization_fixture()
    agent = agent_fixture(scope)

    member =
      member_fixture(scope, :user, %{
        permissions: ["ai.use"],
        agents: [agent.id],
        models: ["qwen3.5:4b", "catalog-model"]
      })

    %{scope: scope, agent: agent, member: member}
  end

  test "current grants and policy restrictions intersect in both resource dimensions", %{
    scope: scope,
    agent: agent,
    member: member
  } do
    resources = %{agent_id: agent.id, model: "qwen3.5:4b"}
    assert {:ok, _} = Policies.snapshot_for_request(member.scope, resources)

    assert {:error, :model_not_allowed} =
             Policies.snapshot_for_request(member.scope, %{resources | model: "catalog-model"})

    {:ok, current} = Policies.current(scope)

    {:ok, version} =
      Policies.create_version(scope, Map.put(Configuration.default(), "allowed_agents", []))

    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    assert {:error, :agent_not_allowed} = Policies.snapshot_for_request(member.scope, resources)

    {:ok, current} = Policies.current(scope)
    {:ok, version} = Policies.create_version(scope, Configuration.default())
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)

    assert {:ok, _} =
             Organizations.update_member(scope, member.membership.id, %{
               grants: %{permissions: ["ai.use"], agents: [agent.id], models: []}
             })

    assert {:error, :forbidden} = Policies.snapshot_for_request(member.scope, resources)

    assert {:ok, _} =
             Organizations.update_member(scope, member.membership.id, %{
               grants: %{permissions: [], agents: [agent.id], models: ["qwen3.5:4b"]}
             })

    assert {:error, :forbidden} = Policies.snapshot_for_request(member.scope, resources)
  end
end
