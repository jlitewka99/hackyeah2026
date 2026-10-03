defmodule AiControlWeb.OrganizationAgentsLiveTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.{Agents, Organizations}

  test "create, rename, suspend and restore through the real controls", %{conn: conn} do
    scope = organization_fixture()

    {:ok, view, _} =
      live(log_in_user(conn, scope.user), ~p"/organizations/#{scope.organization.id}/agents")

    assert has_element?(view, "#agents-empty")
    view |> form("#agent-create-form", agent: %{name: "New assistant"}) |> render_submit()
    {:ok, [agent]} = Agents.list_agents(scope)
    assert has_element?(view, "#agents-#{agent.id}")
    view |> element("#edit-agent-#{agent.id}") |> render_click()

    view
    |> form("#agent-edit-form-#{agent.id}", agent: %{name: "Renamed assistant"})
    |> render_submit()

    assert {:ok, %{name: "Renamed assistant"}} = Agents.fetch_agent(scope, agent.id)
    view |> element("#status-agent-#{agent.id}") |> render_click()
    assert has_element?(view, "#agents-#{agent.id} [data-status=suspended]")
    view |> element("#status-agent-#{agent.id}") |> render_click()
    assert has_element?(view, "#agents-#{agent.id} [data-status=active]")
  end

  test "read-only selected resources hide actions and reject forged events", %{conn: conn} do
    scope = organization_fixture()
    allowed = agent_fixture(scope)
    hidden = agent_fixture(scope)
    reader = member_fixture(scope, :user, %{permissions: ["agents.read"], agents: [allowed.id]})

    {:ok, view, _} =
      live(log_in_user(conn, reader.user), ~p"/organizations/#{scope.organization.id}/agents")

    assert has_element?(view, "#agents-#{allowed.id}")
    refute has_element?(view, "#agents-#{hidden.id}")
    refute has_element?(view, "#agent-create-form")
    refute has_element?(view, "#edit-agent-#{allowed.id}")
    render_click(view, "status", %{id: allowed.id, status: "suspended"})
    assert {:ok, %{status: :active}} = Agents.fetch_agent(scope, allowed.id)
    render_submit(view, "create", %{agent: %{name: "Forged"}})
    assert {:ok, agents} = Agents.list_agents(scope)
    assert length(agents) == 2
  end

  test "HTTP checks the feature grant and organization boundary", %{conn: conn} do
    scope = organization_fixture()
    other = organization_fixture()
    admin = member_fixture(scope, :admin)
    conn = log_in_user(conn, admin.user)
    assert html_response(get(conn, ~p"/organizations/#{scope.organization.id}/agents"), 403)
    assert html_response(get(conn, ~p"/organizations/#{other.organization.id}/agents"), 404)
  end

  test "permission loss closes the open registry", %{conn: conn} do
    scope = organization_fixture()
    user = member_fixture(scope, :user, %{permissions: ["agents.read"], agents: ["*"]})

    {:ok, view, _} =
      live(log_in_user(conn, user.user), ~p"/organizations/#{scope.organization.id}/agents")

    assert {:ok, _} =
             Organizations.update_member(scope, user.membership.id, %{grants: %{permissions: []}})

    assert_redirect(view, ~p"/organizations/#{scope.organization.id}")
  end

  test "resource loss removes rows and an open editor", %{conn: conn} do
    scope = organization_fixture()
    agent = agent_fixture(scope)

    user =
      member_fixture(scope, :user, %{
        permissions: ["agents.read", "agents.manage"],
        agents: [agent.id]
      })

    {:ok, view, _} =
      live(log_in_user(conn, user.user), ~p"/organizations/#{scope.organization.id}/agents")

    view |> element("#edit-agent-#{agent.id}") |> render_click()
    assert has_element?(view, "#agent-edit-form-#{agent.id}")

    assert {:ok, _} =
             Organizations.update_member(scope, user.membership.id, %{
               grants: %{permissions: ["agents.read"], agents: []}
             })

    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#agents-#{agent.id}")
    refute has_element?(view, "#agent-edit-form-#{agent.id}")
  end
end
