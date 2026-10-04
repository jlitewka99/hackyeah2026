defmodule AiControlWeb.OrganizationWorkflowsLiveTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures
  import AiControl.WorkflowsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.{Audit, Organizations, Repo, Workflows}
  alias AiControl.Audit.{Event, Export, Filters, Serializer}

  test "explicit grants restrict participants, decisions and stop", %{conn: conn} do
    c = workflow_fixture()
    hidden = agent_fixture(c.scope)

    {:ok, child} =
      Workflows.delegate(
        c.principal,
        c.run.id,
        c.participant.id,
        %{"target_agent_id" => hidden.id},
        Ecto.UUID.generate()
      )

    denied = member_fixture(c.scope)
    path = ~p"/organizations/#{c.scope.organization.id}/runs"
    assert get(log_in_user(conn, denied.user), path).status == 403

    reader =
      member_fixture(c.scope, :user, %{permissions: ["workflows.read"], agents: [c.agent.id]})

    {:ok, view, _} = live(log_in_user(conn, reader.user), path <> "/#{c.run.id}")
    assert has_element?(view, "#run-tokens")
    assert has_element?(view, "#participants-#{c.participant.id}")
    refute has_element?(view, "#participants-#{child.id}")
    refute has_element?(view, "#run-stop")
    assert has_element?(view, "#run-events-restricted")

    {:ok, _} =
      Organizations.update_member(c.scope, reader.membership.id, %{
        grants: %{permissions: ["workflows.read", "workflows.manage"], agents: [c.agent.id]}
      })

    send(view.pid, :workflows_changed)
    assert has_element?(view, "#run-stop")
    view |> element("#run-stop") |> render_click()
    assert has_element?(view, "#run-stop-confirmation")
    assert_push_event(view, "workflow-focus", %{target: "confirm"})
    view |> element("#run-stop-cancel") |> render_click()
    refute has_element?(view, "#run-stop-confirmation")
    assert_push_event(view, "workflow-focus", %{target: "stop"})
    view |> element("#run-stop") |> render_click()
    view |> element("#run-stop-confirm") |> render_click()
    assert has_element?(view, "#run-status", "Stopped")
    assert_push_event(view, "workflow-focus", %{target: "status"})
    refute has_element?(view, "#run-stop")
  end

  test "filters and organization updates refresh the stream", %{conn: conn} do
    c = workflow_fixture()
    path = ~p"/organizations/#{c.scope.organization.id}/runs"
    {:ok, view, _} = live(log_in_user(conn, c.scope.user), path)
    assert has_element?(view, "#runs-#{c.run.id}")
    view |> form("#run-filters", filters: %{status: "completed", agent_id: ""}) |> render_submit()
    refute has_element?(view, "#runs-#{c.run.id}")
    assert has_element?(view, "#runs-empty")
    {:ok, _} = Workflows.transition(c.principal, c.run.id, "complete")
    send(view.pid, :workflows_changed)
    assert has_element?(view, "#runs-#{c.run.id}")
    view |> form("#run-filters", filters: %{status: "", agent_id: "invalid"}) |> render_submit()
    assert has_element?(view, "#runs-error")
    refute has_element?(view, "#runs-empty")
  end

  test "workflow history and JSONL hide unassigned participants", %{conn: conn} do
    c = workflow_fixture()
    hidden = agent_fixture(c.scope)

    {:ok, child} =
      Workflows.delegate(
        c.principal,
        c.run.id,
        c.participant.id,
        %{"target_agent_id" => hidden.id},
        Ecto.UUID.generate()
      )

    reader =
      member_fixture(c.scope, :user, %{
        permissions: ["workflows.read", "events.read", "events.export"],
        agents: [c.agent.id]
      })

    {:ok, view, _} =
      live(
        log_in_user(conn, reader.user),
        ~p"/organizations/#{c.run.organization_id}/runs/#{c.run.id}"
      )

    assert has_element?(view, "#run-event-list")
    {:ok, filters} = Filters.parse(%{"run_id" => c.run.id})
    {:ok, page} = Audit.page_events(reader.scope, filters)
    evidence = page.events |> Enum.map(&Serializer.event/1) |> Jason.encode!()
    refute evidence =~ child.id
    refute evidence =~ hidden.id

    assert {:ok, {lines, _}} =
             Export.run(reader.scope, filters, [], fn current, batch ->
               {:ok, current ++ batch}
             end)

    refute Enum.join(lines) =~ child.id
    refute Enum.join(lines) =~ hidden.id
    event = Repo.get_by!(Event, event_type: "workflow.delegated")
    assert {:error, :not_found} = Audit.get_event(reader.scope, event.id)
  end

  test "pagination and long goals remain accessible through stable controls", %{conn: conn} do
    c = workflow_fixture()

    for index <- 1..52 do
      Repo.insert!(%{
        c.run
        | id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate(),
          goal: String.duplicate("SyntheticLongGoal", 14),
          status: "completed",
          started_at: DateTime.add(c.run.started_at, -index),
          finished_at: c.run.started_at
      })
    end

    {:ok, view, _} =
      live(log_in_user(conn, c.scope.user), ~p"/organizations/#{c.run.organization_id}/runs")

    assert has_element?(view, "#runs-next")
    view |> element("#runs-next") |> render_click()
    assert has_element?(view, "#runs-first")
    refute has_element?(view, "#runs-next")
    refute has_element?(view, "#runs-#{c.run.id}")
    view |> element("#runs-first") |> render_click()
    assert has_element?(view, "#runs-#{c.run.id}")
  end
end
