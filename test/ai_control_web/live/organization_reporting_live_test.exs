defmodule AiControlWeb.OrganizationReportingLiveTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.{Audit, Organizations}

  test "overview is useful without reporting grants and each page checks its own permission", %{
    conn: conn
  } do
    scope = organization_fixture()
    reader = member_fixture(scope)
    conn = log_in_user(conn, reader.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}")
    assert has_element?(view, "#organization-overview")
    assert has_element?(view, "#your-role-heading")
    refute has_element?(view, "#overview-activity")
    refute has_element?(view, "#overview-budget")
    refute has_element?(view, "#overview-controls")

    for page <- ~w(events budgets signatures) do
      assert get(conn, "/organizations/#{scope.organization.id}/#{page}").status == 403
    end
  end

  test "overview displays actual request counts and PubSub refreshes without remounting", %{
    conn: conn
  } do
    scope = organization_fixture()

    {:ok, view, _} =
      live(log_in_user(conn, scope.user), ~p"/organizations/#{scope.organization.id}")

    assert has_element?(view, "#overview-count-allow dd", "0")

    {:ok, _} =
      Audit.record_gateway(scope, Ecto.UUID.generate(), "completed", 123, nil, :output, nil, %{
        operation: "chat",
        timings: %{"request" => 123}
      })

    send(view.pid, :refresh_reporting)
    assert has_element?(view, "#overview-count-allow dd", "1")
    assert has_element?(view, "#latencies-request")

    view
    |> form("#overview-filters",
      filters: %{range: "custom", from: "2026-10-04T03:00", to: "2026-10-04T02:00"}
    )
    |> render_submit()

    assert has_element?(view, "#overview-filters [aria-invalid=true]")
  end

  test "events filter, detail chronology and download require current access", %{conn: conn} do
    scope = organization_fixture()
    {:ok, event} = Audit.record_gateway(scope, Ecto.UUID.generate(), "completed", 3)
    reader = member_fixture(scope, :user, %{permissions: ["events.read"]})
    conn = log_in_user(conn, reader.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/events")
    assert has_element?(view, "#events-#{event.id}")
    refute has_element?(view, "#events-export")
    view |> form("#event-filters", filters: %{kind: "decision"}) |> render_submit()
    assert has_element?(view, "#events-empty")
    {:ok, details, _} = live(conn, ~p"/organizations/#{scope.organization.id}/events/#{event.id}")
    assert has_element?(details, "#event-evidence")
    assert has_element?(details, "#chronology-#{event.id}")

    {:ok, _} =
      Organizations.update_member(scope, reader.membership.id, %{grants: %{permissions: []}})

    assert_redirect(details, ~p"/organizations/#{scope.organization.id}")
  end

  test "read-only budgets and signatures work without policy or event access", %{conn: conn} do
    scope = organization_fixture()
    agent = agent_fixture(scope)
    hidden = agent_fixture(scope)

    reader =
      member_fixture(scope, :user, %{
        permissions: ["budgets.read", "signatures.read"],
        agents: [agent.id]
      })

    conn = log_in_user(conn, reader.user)
    {:ok, budgets, _} = live(conn, ~p"/organizations/#{scope.organization.id}/budgets")
    assert has_element?(budgets, "#agents-#{agent.id}")
    refute has_element?(budgets, "#agents-#{hidden.id}")
    refute has_element?(budgets, "#budget-report-links a", "Policy configuration")
    {:ok, signatures, _} = live(conn, ~p"/organizations/#{scope.organization.id}/signatures")
    assert has_element?(signatures, "#signatures-exploit\\.eval\\.v1")
    assert has_element?(signatures, "#signature-checksum")
    refute has_element?(signatures, "#signature-detections")
    {:ok, _} = Organizations.remove_member(scope, reader.membership.id)
    assert_redirect(budgets, ~p"/organizations")
    assert_redirect(signatures, ~p"/organizations")
  end

  test "live reporting refresh preserves an unsaved agent name", %{conn: conn} do
    scope = organization_fixture()
    agent = agent_fixture(scope)

    {:ok, view, _} =
      live(log_in_user(conn, scope.user), ~p"/organizations/#{scope.organization.id}/agents")

    view |> element("#edit-agent-#{agent.id}") |> render_click()

    view
    |> form("#agent-edit-form-#{agent.id}", agent: %{name: "Unsaved draft"})
    |> render_change()

    send(view.pid, :dashboard_changed)
    send(view.pid, :refresh_reporting)
    send(view.pid, :reporting_tick)
    assert has_element?(view, "#agent-edit-name-#{agent.id}[value='Unsaved draft']")
    assert {:ok, stored} = AiControl.Agents.fetch_agent(scope, agent.id, "agents.read")
    assert stored.name == agent.name
  end
end
