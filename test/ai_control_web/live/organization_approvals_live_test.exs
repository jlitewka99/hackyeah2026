defmodule AiControlWeb.OrganizationApprovalsLiveTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.ApprovalsFixtures
  import AiControl.OrganizationsFixtures
  import Phoenix.LiveViewTest

  alias AiControl.{Approvals, Organizations, Repo}
  alias AiControl.Approvals.Approval
  alias AiControl.Tools.Sandbox

  setup do
    c = approval_fixture()
    Map.put(c, :approval, pending(c))
  end

  test "reader can inspect escaped payload, admin confirms without executing", c do
    reader =
      member_fixture(c.scope, :user, %{permissions: ["approvals.read"], agents: [c.agent.id]})

    {:ok, view, _} = live(log_in_user(c.conn, reader.user), detail(c))
    assert has_element?(view, "#approval-payload", "<script>")
    refute has_element?(view, "#approval-payload script")
    refute has_element?(view, "#approval-approve")
    assert has_element?(view, "#approval-history[phx-update='stream']")

    admin =
      member_fixture(c.scope, :admin, %{
        permissions: ["approvals.read", "approvals.manage"],
        agents: [c.agent.id]
      })

    {:ok, view, _} = live(log_in_user(c.conn, admin.user), detail(c))
    view |> element("#approval-approve") |> render_click()
    assert has_element?(view, "#approval-confirmation")
    assert_push_event(view, "approval-focus", %{id: "approval-confirm"})
    assert Repo.get!(Approval, c.approval.id).status == "pending"
    view |> element("#approval-cancel") |> render_click()
    assert_push_event(view, "approval-focus", %{id: "approval-approve"})
    refute has_element?(view, "#approval-confirmation")
    view |> element("#approval-approve") |> render_click()
    view |> element("#approval-confirm") |> render_click()
    assert has_element?(view, "#approval-status", "Approved")
    assert_push_event(view, "approval-focus", %{id: "approval-status"})
    refute has_element?(view, "#approval-approve")
    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end

  test "filters, pagination and PubSub update streams and terminal preview removal", c do
    path = ~p"/organizations/#{c.scope.organization.id}/approvals"
    {:ok, list, _} = live(log_in_user(c.conn, c.scope.user), path)
    assert has_element?(list, "#approvals-#{c.approval.id}")

    list
    |> form("#approval-filters",
      filters: %{status: "rejected", kind: "", agent_id: "", run_id: ""}
    )
    |> render_submit()

    assert has_element?(list, "#approvals-empty")
    assert {:ok, _} = Approvals.decide(c.scope, c.approval.id, :reject, c.approval.revision)
    send(list.pid, :approvals_changed)
    assert has_element?(list, "#approvals-#{c.approval.id}")
    {:ok, view, _} = live(log_in_user(c.conn, c.scope.user), detail(c))
    refute has_element?(view, "#approval-payload")
    assert has_element?(view, "#approval-preview-unavailable")
    list |> form("#approval-filters", filters: %{agent_id: "invalid"}) |> render_submit()
    assert has_element?(list, "#approvals-error")

    for _ <- 1..51 do
      Repo.insert!(%{
        c.approval
        | id: Ecto.UUID.generate(),
          operation_request_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
      })
    end

    {:ok, list, _} = live(log_in_user(c.conn, c.scope.user), path)
    assert has_element?(list, "#approvals-next")
    list |> element("#approvals-next") |> render_click()
    assert has_element?(list, "#approvals-first")
    refute has_element?(list, "#approvals-next")
  end

  test "a concurrent decision clears confirmation and cannot be overwritten", c do
    {:ok, view, _} = live(log_in_user(c.conn, c.scope.user), detail(c))
    view |> element("#approval-approve") |> render_click()
    Approvals.decide(c.scope, c.approval.id, :reject, c.approval.revision)
    send(view.pid, :approvals_changed)
    assert has_element?(view, "#approval-status", "Rejected")
    refute has_element?(view, "#approval-confirm")
    assert Repo.get!(Approval, c.approval.id).status == "rejected"
  end

  test "revoked and unassigned access never exposes the preview", c do
    reader =
      member_fixture(c.scope, :user, %{permissions: ["approvals.read"], agents: [c.agent.id]})

    {:ok, view, _} = live(log_in_user(c.conn, reader.user), detail(c))
    assert has_element?(view, "#approval-payload")

    Organizations.update_member(c.scope, reader.membership.id, %{
      grants: %{permissions: ["approvals.read"], agents: []}
    })

    send(view.pid, :approvals_changed)
    refute has_element?(view, "#approval-payload")
    assert has_element?(view, "#approval-error")
    denied = member_fixture(c.scope)
    assert get(log_in_user(c.conn, denied.user), detail(c)).status == 403
  end

  defp detail(c), do: ~p"/organizations/#{c.scope.organization.id}/approvals/#{c.approval.id}"
end
