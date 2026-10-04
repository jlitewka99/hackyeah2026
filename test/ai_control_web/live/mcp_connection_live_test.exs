defmodule AiControlWeb.MCPConnectionLiveTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.MCP.Config

  test "readers see connection instructions without key management or a revealed secret" do
    scope = organization_fixture()
    agent = agent_fixture(scope)
    reader = member_fixture(scope, :user, %{permissions: ["api_keys.read"], agents: [agent.id]})

    {:ok, view, _} =
      live(
        log_in_user(build_conn(), reader.user),
        ~p"/organizations/#{scope.organization.id}/api-keys"
      )

    assert has_element?(view, "#mcp-connection")

    assert has_element?(
             view,
             "#mcp-endpoint[readonly][value='#{Config.endpoint()}']"
           )

    assert has_element?(view, "#copy-mcp-endpoint")
    assert has_element?(view, "#copy-mcp-status[aria-live=polite]")
    assert has_element?(view, "#mcp-connection-details code", "Authorization: Bearer <API_KEY>")
    refute has_element?(view, "#api-key-create-form")
    refute has_element?(view, "#api-key-secret")
  end

  test "creating a key leaves the MCP instructions free of the one-time secret" do
    scope = organization_fixture()
    agent = agent_fixture(scope)

    {:ok, view, _} =
      live(
        log_in_user(build_conn(), scope.user),
        ~p"/organizations/#{scope.organization.id}/api-keys"
      )

    view
    |> form("#api-key-create-form",
      api_key: %{label: "MCP integration", agent_id: agent.id, expiry_mode: "ninety_days"}
    )
    |> render_submit()

    assert has_element?(view, "#api-key-secret")
    assert has_element?(view, "#mcp-connection-details code", "Authorization: Bearer <API_KEY>")

    assert has_element?(
             view,
             "#mcp-endpoint[readonly][value='#{Config.endpoint()}']"
           )

    view |> element("#dismiss-api-key-secret") |> render_click()
    refute has_element?(view, "#api-key-secret")
    assert has_element?(view, "#mcp-connection")
  end

  test "members without API-key read access cannot reach the instructions" do
    scope = organization_fixture()
    member = member_fixture(scope, :user)
    conn = log_in_user(build_conn(), member.user)
    conn = get(conn, ~p"/organizations/#{scope.organization.id}/api-keys")
    assert conn.status == 403
  end
end
