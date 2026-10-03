defmodule AiControlWeb.OrganizationApiKeysLiveTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.{Agents, ApiKeys, Organizations}

  setup %{conn: conn} do
    scope = organization_fixture()
    %{scope: scope, agent: agent_fixture(scope), conn: log_in_user(conn, scope.user)}
  end

  test "creation reveals a working secret once; dismissal and remount remove it", %{
    conn: conn,
    scope: scope,
    agent: agent
  } do
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/api-keys")

    view
    |> form("#api-key-create-form",
      api_key: %{label: "Live key", agent_id: agent.id, expiry_mode: "ninety_days"}
    )
    |> render_submit()

    token = secret(view)
    assert {:ok, _} = ApiKeys.authenticate(token)
    assert has_element?(view, "#copy-api-key")
    view |> element("#dismiss-api-key-secret") |> render_click()
    refute has_element?(view, "#api-key-secret")
    {:ok, remounted, _} = live(conn, ~p"/organizations/#{scope.organization.id}/api-keys")
    refute has_element?(remounted, "#api-key-secret")
    assert has_element?(remounted, "#api-key-list .key-row")
  end

  test "key workflows do not require agents.read, and filters reset streams", %{
    scope: scope,
    agent: agent
  } do
    other = agent_fixture(scope)
    {first, _} = key_fixture(scope, agent)
    {second, _} = key_fixture(scope, other)

    user =
      member_fixture(scope, :user, %{
        permissions: ["api_keys.read", "api_keys.manage"],
        agents: [agent.id]
      })

    {:ok, view, _} =
      live(
        log_in_user(build_conn(), user.user),
        ~p"/organizations/#{scope.organization.id}/api-keys"
      )

    assert has_element?(view, "#api-key-create-form")
    assert has_element?(view, "#keys-#{first.id}")
    refute has_element?(view, "#keys-#{second.id}")

    refute has_element?(
             view,
             "#desktop-navigation a[href='/organizations/#{scope.organization.id}/agents']"
           )

    view |> form("#api-key-filter-form", filter: %{agent_id: agent.id}) |> render_change()
    assert has_element?(view, "#keys-#{first.id}")
    render_change(view, "filter", %{filter: %{agent_id: other.id}})
    refute has_element?(view, "#keys-#{second.id}")
    render_submit(view, "create", %{api_key: %{label: "Forbidden", agent_id: other.id}})
    assert {:ok, keys} = ApiKeys.list_keys(scope)
    assert length(keys) == 2
  end

  test "rotation confirms immediate revocation and produces a replacement", %{
    conn: conn,
    scope: scope,
    agent: agent
  } do
    {key, token} = key_fixture(scope, agent)
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/api-keys")
    view |> element("#rotate-key-#{key.id}") |> render_click()
    assert has_element?(view, "#rotation-warning")
    assert {:ok, _} = ApiKeys.authenticate(token)

    view
    |> form("#api-key-create-form", api_key: %{label: "Rotated", expiry_mode: "never"})
    |> render_submit()

    assert {:error, :invalid_api_key} = ApiKeys.authenticate(token)
    assert {:ok, principal} = ApiKeys.authenticate(secret(view))
    view |> element("#revoke-key-#{principal.api_key_id}") |> render_click()
    refute has_element?(view, "#api-key-secret")
    assert has_element?(view, "#keys-#{principal.api_key_id} [data-status=revoked]")
  end

  test "custom expiration validates inline and preserves the selected agent", %{
    conn: conn,
    scope: scope,
    agent: agent
  } do
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/api-keys")

    view
    |> form("#api-key-create-form",
      api_key: %{label: "Custom", agent_id: agent.id, expiry_mode: "custom"}
    )
    |> render_change()

    assert has_element?(view, "#api_key_expiry_at")

    view
    |> form("#api-key-create-form",
      api_key: %{
        label: "Custom",
        agent_id: agent.id,
        expiry_mode: "custom",
        expiry_at: "2020-01-01T00:00"
      }
    )
    |> render_submit()

    assert has_element?(view, "#api_key_expiry_at[aria-invalid=true]")
    refute has_element?(view, "#api-key-secret")
  end

  test "management loss clears an already revealed secret while retaining readable metadata", %{
    scope: scope,
    agent: agent
  } do
    user =
      member_fixture(scope, :user, %{
        permissions: ["api_keys.read", "api_keys.manage"],
        agents: [agent.id]
      })

    {:ok, view, _} =
      live(
        log_in_user(build_conn(), user.user),
        ~p"/organizations/#{scope.organization.id}/api-keys"
      )

    view
    |> form("#api-key-create-form", api_key: %{label: "Temporary", agent_id: agent.id})
    |> render_submit()

    assert has_element?(view, "#api-key-secret")

    assert {:ok, _} =
             Organizations.update_member(scope, user.membership.id, %{
               grants: %{permissions: ["api_keys.read"], agents: [agent.id]}
             })

    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#api-key-secret")
    refute has_element?(view, "#api-key-create-form")
    assert has_element?(view, "#api-key-list .key-row")
  end

  test "selector loss clears secrets and rows in the open panel", %{scope: scope, agent: agent} do
    user =
      member_fixture(scope, :user, %{
        permissions: ["api_keys.read", "api_keys.manage"],
        agents: [agent.id]
      })

    {:ok, view, _} =
      live(
        log_in_user(build_conn(), user.user),
        ~p"/organizations/#{scope.organization.id}/api-keys"
      )

    view
    |> form("#api-key-create-form", api_key: %{label: "Temporary", agent_id: agent.id})
    |> render_submit()

    assert has_element?(view, "#api-key-secret")

    assert {:ok, _} =
             Organizations.update_member(scope, user.membership.id, %{
               grants: %{permissions: ["api_keys.read", "api_keys.manage"], agents: []}
             })

    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#api-key-secret")
    refute has_element?(view, "#api-key-list .key-row")
    assert has_element?(view, "#key-agents-empty")
  end

  test "read access loss closes the view and organization suspension preserves the session", %{
    scope: scope
  } do
    user = member_fixture(scope, :user, %{permissions: ["api_keys.read"], agents: ["*"]})
    conn = log_in_user(build_conn(), user.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/api-keys")
    assert {:ok, _} = Organizations.set_status(scope, :suspended)
    assert_redirect(view, ~p"/organizations")
    assert {:ok, _, _} = live(conn, ~p"/users/settings")
  end

  test "read-only users cannot mutate and key routes require their own feature grant", %{
    scope: scope,
    agent: agent
  } do
    {key, token} = key_fixture(scope, agent)
    reader = member_fixture(scope, :user, %{permissions: ["api_keys.read"], agents: [agent.id]})

    {:ok, view, _} =
      live(
        log_in_user(build_conn(), reader.user),
        ~p"/organizations/#{scope.organization.id}/api-keys"
      )

    refute has_element?(view, "#rotate-key-#{key.id}")
    render_click(view, "revoke", %{id: key.id})
    assert {:ok, _} = ApiKeys.authenticate(token)
    no_access = member_fixture(scope, :admin)

    assert html_response(
             get(
               log_in_user(build_conn(), no_access.user),
               ~p"/organizations/#{scope.organization.id}/api-keys"
             ),
             403
           )
  end

  test "member editor stores specific agent selections", %{conn: conn, scope: scope, agent: agent} do
    user = member_fixture(scope)
    other = agent_fixture(scope)

    {:ok, view, _} =
      live(conn, ~p"/organizations/#{scope.organization.id}/members/#{user.membership.id}/access")

    assert has_element?(view, "#member-access-agent-#{agent.id}[type=checkbox]")
    assert has_element?(view, "#member-access-agent-#{other.id}[type=checkbox]")

    view
    |> form("#member-access-form",
      access: %{
        role: "user",
        permissions: ["agents.read"],
        agents: ["false", agent.id, "false", other.id],
        all_agents: "false"
      }
    )
    |> render_submit()

    assert {:ok, current} = Organizations.refresh_scope(user.scope)
    assert Enum.sort(current.grants.agents) == Enum.sort([agent.id, other.id])
  end

  test "suspending an agent updates its key state and clears the revealed secret", %{
    conn: conn,
    scope: scope,
    agent: agent
  } do
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/api-keys")

    view
    |> form("#api-key-create-form", api_key: %{label: "Temporary", agent_id: agent.id})
    |> render_submit()

    assert has_element?(view, "#api-key-secret")
    assert {:ok, _} = Agents.set_status(scope, agent.id, :suspended)
    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#api-key-secret")
    assert has_element?(view, "#key-agents-empty")
  end

  defp secret(view) do
    [token] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#api-key-secret")
      |> LazyHTML.attribute("value")

    token
  end
end
