defmodule AiControl.AgentsTest do
  use AiControl.DataCase, async: true

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.{Agents, Organizations}
  alias AiControl.Organizations.{Access, ResourceResolver}

  test "registry owns stable UUIDs and ignores client-selected organization and status" do
    first = organization_fixture()
    second = organization_fixture()

    agent =
      agent_fixture(first, %{
        name: "  Support agent  ",
        organization_id: second.organization.id,
        status: "suspended"
      })

    assert agent.name == "Support agent"
    assert agent.organization_id == first.organization.id
    assert agent.status == :active
    assert {:ok, _} = Ecto.UUID.cast(agent.id)
    assert ResourceResolver.owned?(first.organization.id, :agent, agent.id)
    refute ResourceResolver.owned?(second.organization.id, :agent, agent.id)
    refute ResourceResolver.owned?(first.organization.id, :agent, "malformed")
    refute ResourceResolver.owned?(first.organization.id, :model, "model")

    assert {:error, :forbidden} =
             Access.authorize(first, "ai.use", %{agent: agent.id, model: "model"})
  end

  test "read and management grants stay independent of administrative roles" do
    organization = organization_fixture()
    agent = agent_fixture(organization)
    admin = member_fixture(organization, :admin)

    reader =
      member_fixture(organization, :user, %{permissions: ["agents.read"], agents: [agent.id]})

    manager =
      member_fixture(organization, :user, %{permissions: ["agents.manage"], agents: [agent.id]})

    assert {:error, :forbidden} = Agents.list_agents(admin.scope)
    assert {:ok, [^agent]} = Agents.list_agents(reader.scope)
    assert {:error, :forbidden} = Agents.update_agent(reader.scope, agent.id, %{name: "Changed"})
    assert {:error, :forbidden} = Agents.list_agents(manager.scope)
    assert {:ok, updated} = Agents.update_agent(manager.scope, agent.id, %{name: "Changed"})
    assert updated.id == agent.id
    assert updated.name == "Changed"
    assert {:error, :forbidden} = Agents.create_agent(manager.scope, %{name: "New agent"})
  end

  test "specific grants filter reads, deny foreign IDs and preserve suspended ownership" do
    organization = organization_fixture()
    other = organization_fixture()
    allowed = agent_fixture(organization)
    hidden = agent_fixture(organization)
    foreign = agent_fixture(other)

    member =
      member_fixture(organization, :user, %{
        permissions: ["agents.read", "agents.manage"],
        agents: [allowed.id]
      })

    assert {:ok, [^allowed]} = Agents.list_agents(member.scope)

    for id <- [hidden.id, foreign.id, "invalid"] do
      assert {:error, :forbidden} = Agents.fetch_agent(member.scope, id)
      assert {:error, :forbidden} = Agents.set_status(member.scope, id, :suspended)
    end

    assert {:ok, _} = Agents.set_status(member.scope, allowed.id, :suspended)
    assert ResourceResolver.owned?(organization.organization.id, :agent, allowed.id)
    assert {:ok, %{status: :active}} = Agents.set_status(member.scope, allowed.id, :active)
    assert {:error, :forbidden} = Agents.set_status(member.scope, allowed.id, :invalid)
  end

  test "wildcards include future agents and authorization refreshes stale scopes" do
    organization = organization_fixture()

    member =
      member_fixture(organization, :user, %{
        permissions: ["agents.read", "agents.manage"],
        agents: ["*"]
      })

    assert {:ok, []} = Agents.list_agents(member.scope)
    assert {:ok, agent} = Agents.create_agent(member.scope, %{name: "Future agent"})
    assert {:ok, [^agent]} = Agents.list_agents(member.scope)

    assert {:ok, _} =
             Organizations.update_member(organization, member.membership.id, %{
               grants: %{permissions: []}
             })

    assert {:error, :forbidden} =
             Agents.update_agent(member.scope, agent.id, %{name: "Forbidden"})
  end

  test "real registry enables delegation only within the manager's selectors" do
    organization = organization_fixture()
    agent = agent_fixture(organization)
    hidden = agent_fixture(organization)

    admin =
      member_fixture(organization, :admin, %{permissions: ["agents.read"], agents: [agent.id]})

    user = member_fixture(organization)
    assert {:ok, [^agent]} = Agents.list_assignable_agents(admin.scope)

    assert {:ok, _} =
             Organizations.update_member(admin.scope, user.membership.id, %{
               grants: %{permissions: ["agents.read"], agents: [agent.id]}
             })

    assert {:error, :forbidden} =
             Organizations.update_member(admin.scope, user.membership.id, %{
               grants: %{agents: [hidden.id]}
             })

    assert {:error, :unknown_resource} =
             Organizations.update_member(organization, user.membership.id, %{
               grants: %{agents: [Ecto.UUID.generate()]}
             })

    assert {:error, :forbidden} = Agents.list_assignable_agents(user.scope)
  end

  test "invalid names do not register agents" do
    organization = organization_fixture()

    for name <- ["", " ", String.duplicate("x", 121)] do
      assert {:error, %Ecto.Changeset{}} = Agents.create_agent(organization, %{name: name})
    end

    assert {:ok, []} = Agents.list_agents(organization)
  end
end
