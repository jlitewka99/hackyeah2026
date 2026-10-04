defmodule AiControlWeb.OrganizationBackgroundLiveTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.{Background, Organizations, Repo}
  alias AiControl.Background.Workers.MetricsReport

  test "terminal runs without cases explain why no results were recorded", %{conn: conn} do
    scope = organization_fixture()
    {:ok, run} = Background.enqueue(scope, "gateway_tests")
    :ok = Background.cancel(scope, run.id)
    conn = log_in_user(conn, scope.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/tests/#{run.id}")
    assert has_element?(view, "#test-cases-empty", "cancelled before")
    assert has_element?(view, "#test-run-summary .field-error")
    refute has_element?(view, "#test-run-progress")
  end

  test "tests history and details require tests.read and run controls require tests.run", %{
    conn: conn
  } do
    scope = organization_fixture()
    member = member_fixture(scope, :user, %{permissions: ["tests.read"]})
    conn = log_in_user(conn, member.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/tests")
    assert has_element?(view, "#tests-run[disabled]")
    assert has_element?(view, "#tests-read-only")
    assert has_element?(view, "#tests-empty")
    {:ok, run} = Background.enqueue(scope, "gateway_tests")
    send(view.pid, :refresh_reporting)
    assert has_element?(view, "#run-details-#{run.id}")
    {:ok, detail, _} = live(conn, ~p"/organizations/#{scope.organization.id}/tests/#{run.id}")
    assert has_element?(detail, "#test-run-progress")
    refute has_element?(detail, "#run-cancel-#{run.id}")

    {:ok, _} =
      Organizations.update_member(scope, member.membership.id, %{grants: %{permissions: []}})

    assert_redirect(detail, ~p"/organizations/#{scope.organization.id}")
  end

  test "reports can be queued and completed artifacts become available with fresh authorization",
       %{conn: conn} do
    scope = organization_fixture()
    conn = log_in_user(conn, scope.user)
    {:ok, view, _} = live(conn, ~p"/organizations/#{scope.organization.id}/reports")
    assert has_element?(view, "#reports-empty")

    view
    |> form("#reports-form", report: %{kind: "metrics_report", range: "1h"})
    |> render_submit()

    {:ok, [run]} = Background.list(scope, ["metrics_report"])
    assert has_element?(view, "#run-status-#{run.id}")

    assert :ok =
             MetricsReport.perform(%{
               Repo.get!(Oban.Job, run.job_id)
               | attempt: 1
             })

    send(view.pid, :refresh_reporting)
    assert has_element?(view, "#run-download-#{run.id}")

    assert get(conn, ~p"/organizations/#{scope.organization.id}/background/#{run.id}/download").status ==
             200

    other = organization_fixture()

    assert get(conn, ~p"/organizations/#{other.organization.id}/background/#{run.id}/download").status ==
             404
  end

  test "background export preserves the existing HTTP action and packages have explicit empty states",
       %{conn: conn} do
    scope = organization_fixture()
    conn = log_in_user(conn, scope.user)
    {:ok, events, _} = live(conn, ~p"/organizations/#{scope.organization.id}/events")
    assert has_element?(events, "#events-export")
    events |> element("#events-background-export") |> render_click()
    assert_redirect(events, ~p"/organizations/#{scope.organization.id}/reports")
    {:ok, signatures, _} = live(conn, ~p"/organizations/#{scope.organization.id}/signatures")
    assert has_element?(signatures, "#signature-packages-empty")
    assert has_element?(signatures, "#signature-candidates-empty")
  end
end
