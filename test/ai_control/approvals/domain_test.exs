defmodule AiControl.Approvals.DomainTest do
  use AiControl.DataCase, async: false

  import AiControl.ApprovalsFixtures
  import AiControl.OrganizationsFixtures
  import ExUnit.CaptureLog

  alias AiControl.{Approvals, Audit, Organizations, Workflows}
  alias AiControl.Approvals.{Approval, Cipher}
  alias AiControl.Audit.{Export, Filters, Serializer}
  alias AiControl.Gateway.Config, as: GatewayConfig
  alias AiControl.Tools.{Execution, Sandbox}
  alias AiControl.Workflows.{Operation, Run}

  setup do: approval_fixture()

  test "encrypted review is durable, does not execute, and resumes exactly once", c do
    record = pending(c)
    assert record.status == "pending"
    assert {:ok, write_payload()} == Cipher.decrypt(record)
    refute record.ciphertext =~ "Synthetic private"
    refute inspect(record) =~ "ciphertext"
    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
    assert Repo.get_by!(Execution, run_id: c.run.id).status == "awaiting_review"
    assert Repo.get_by!(Operation, run_id: c.run.id).status == "awaiting_review"
    assert Repo.get!(Run, c.run.id).calls == 1
    assert {:error, {:approval_required, %{approval_id: id}}} = review_call(c)
    assert id == record.id
    approve(c, record)
    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
    assert {:ok, _} = review_call(c, write_payload(), approval_id: id)

    assert Sandbox.inspect_state(c.sandbox).files["copy.txt"] ==
             write_payload()["arguments"]["content"]

    assert %{status: "consumed", ciphertext: nil} = Repo.get!(Approval, id)
    assert {:error, :approval_used} = review_call(c, write_payload(), approval_id: id)
    run = Repo.get!(Run, c.run.id)
    assert run.calls == 1
    assert Workflows.evidence(run).tool_calls == 1
  end

  test "changed raw arguments invalidate and delete the preview", c do
    record = c |> pending() |> then(&approve(c, &1))

    assert {:error, :approval_conflict} =
             review_call(c, write_payload("Changed"), approval_id: record.id)

    assert %{status: "invalidated", ciphertext: nil} = Repo.get!(Approval, record.id)
    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end

  test "revision conflicts and rejection require a new logical operation", c do
    record = pending(c)

    assert {:error, :approval_conflict} =
             Approvals.decide(c.scope, record.id, :approve, record.revision + 1)

    assert {:ok, %{status: "rejected", ciphertext: nil}} =
             Approvals.decide(c.scope, record.id, :reject, record.revision)

    assert {:error, :approval_rejected} = review_call(c, write_payload(), approval_id: record.id)
  end

  test "TTLs end at their boundary and approval starts a new bounded interval", c do
    instant = Approvals.now()
    clock = start_supervised!({Agent, fn -> instant end})
    Application.put_env(:ai_control, :approval_clock, fn -> Agent.get(clock, & &1) end)
    on_exit(fn -> Application.delete_env(:ai_control, :approval_clock) end)
    record = pending(c)
    assert DateTime.diff(record.expires_at, instant) == 900
    Agent.update(clock, fn _ -> DateTime.add(instant, 899) end)
    approved = approve(c, record)
    assert DateTime.diff(approved.expires_at, instant) == 1799
    Agent.update(clock, fn _ -> approved.expires_at end)
    assert {:error, :approval_expired} = review_call(c, write_payload(), approval_id: record.id)
    assert %{status: "expired", ciphertext: nil} = Repo.get!(Approval, record.id)
    assert Repo.get_by!(Execution, run_id: c.run.id).status == "rejected"
    assert Repo.get_by!(Operation, run_id: c.run.id).status == "finished"
    fresh = pending(%{c | key: Ecto.UUID.generate()})
    Agent.update(clock, fn _ -> fresh.expires_at end)

    assert {:error, :approval_conflict} =
             Approvals.decide(c.scope, fresh.id, :approve, fresh.revision)

    assert Repo.get!(Approval, fresh.id).status == "expired"
  end

  test "workflow deadline caps both periods and terminal/recovery never dispatches", c do
    Repo.update!(Ecto.Changeset.change(c.run, deadline: DateTime.add(Approvals.now(), 60)))
    record = pending(c)
    assert DateTime.diff(record.expires_at, Approvals.now()) <= 60
    assert approve(c, record).expires_at == record.workflow_deadline
    assert {:ok, _} = Workflows.transition(c.principal, c.run.id, "stop")
    assert %{status: "invalidated", ciphertext: nil} = Repo.get!(Approval, record.id)
    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end

  test "claim recovery is uncertain and cannot restore an authorization", c do
    record = c |> pending() |> then(&approve(c, &1))

    assert {:ok, claimed} =
             Approvals.prepare(
               c.principal,
               "tool",
               write_payload(),
               c.policy,
               Ecto.UUID.generate(),
               run_context: c.reference,
               idempotency_key: c.key,
               approval_id: record.id
             )

    assert claimed.status == "claimed"
    assert :ok = Approvals.reconcile(true)
    assert %{status: "uncertain", ciphertext: nil} = Repo.get!(Approval, record.id)
    assert {:error, :approval_used} = review_call(c, write_payload(), approval_id: record.id)
    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end

  test "organization, owning key and admin selectors are enforced", c do
    record = pending(c)
    foreign = organization_fixture()
    assert {:error, :forbidden} = Approvals.fetch(foreign, record.id)
    other = AiControl.GatewayFixtures.principal_fixture(c.scope, c.agent)
    assert {:error, :forbidden} = Approvals.status(other, record.id)

    reader =
      member_fixture(c.scope, :admin, %{permissions: ["approvals.read"], agents: [c.agent.id]})

    assert {:ok, _} = Approvals.fetch(reader.scope, record.id)

    assert {:error, :forbidden} =
             Approvals.decide(reader.scope, record.id, :approve, record.revision)

    user =
      member_fixture(c.scope, :user, %{
        permissions: ["approvals.read", "approvals.manage"],
        agents: [c.agent.id]
      })

    assert {:error, :forbidden} =
             Approvals.decide(user.scope, record.id, :approve, record.revision)

    unassigned =
      member_fixture(c.scope, :admin, %{permissions: ["approvals.read", "approvals.manage"]})

    assert {:error, :forbidden} = Approvals.fetch(unassigned.scope, record.id)
  end

  test "revoked approver access fails closed on resume", c do
    record = pending(c)

    admin =
      member_fixture(c.scope, :admin, %{
        permissions: ["approvals.read", "approvals.manage"],
        agents: [c.agent.id]
      })

    assert {:ok, _} = Approvals.decide(admin.scope, record.id, :approve, record.revision)

    assert {:ok, _} =
             Organizations.update_member(c.scope, admin.membership.id, %{
               grants: %{permissions: ["approvals.read"], agents: [c.agent.id]}
             })

    assert {:error, :forbidden} = review_call(c, write_payload(), approval_id: record.id)
    assert Repo.get!(Approval, record.id).ciphertext == nil
  end

  test "current policy and budget still apply after approval", c do
    record = c |> pending() |> then(&approve(c, &1))
    review_policy(c.scope, %{"tools" => %{"allowed_tools" => []}})
    assert {:error, :tool_not_allowed} = review_call(c, write_payload(), approval_id: record.id)
    assert %{status: "invalidated", ciphertext: nil} = Repo.get!(Approval, record.id)
    review_policy(c.scope)
    next = %{c | key: Ecto.UUID.generate()}
    approval = next |> pending() |> then(&approve(next, &1))
    review_policy(c.scope, %{}, %{"tool_calls" => 0})

    assert {:error, :workflow_limit_exceeded} =
             review_call(next, write_payload(), approval_id: approval.id)

    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end

  test "each waiting tool attempt pays the current hourly request budget", c do
    review_policy(c.scope, %{"budgets" => %{"organization" => %{"requests_per_hour" => 2}}})
    record = pending(c)
    assert {:error, {:approval_required, _}} = review_call(c)
    approve(c, record)

    assert {:error, {:request_budget_exceeded, _}} =
             review_call(c, write_payload(), approval_id: record.id)

    assert %{status: "invalidated", ciphertext: nil} = Repo.get!(Approval, record.id)
    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end

  test "hard block wins; redacted payload is the only preview that can resume", c do
    old = Application.fetch_env!(:ai_control, AiControl.Gateway.Config)

    Application.put_env(
      :ai_control,
      GatewayConfig,
      Keyword.put(old, :guards, GatewayConfig.guard_modules())
    )

    on_exit(fn -> Application.put_env(:ai_control, GatewayConfig, old) end)

    guards =
      Map.put(c.policy.settings["guards"], "pii", %{
        "enabled" => true,
        "required" => true,
        "stages" => ["input"]
      })

    review_policy(c.scope, %{"guards" => guards, "rules" => %{"pii" => %{"action" => "block"}}})

    assert {:error, :policy_blocked} =
             review_call(c, write_payload("Contact: synthetic@example.test"))

    assert Repo.aggregate(Approval, :count) == 0
    review_policy(c.scope, %{"guards" => guards, "rules" => %{"pii" => %{"action" => "redact"}}})
    next = %{c | key: Ecto.UUID.generate()}
    record = pending(next, write_payload("Contact: synthetic@example.test"))
    assert {:ok, preview} = Cipher.decrypt(record)
    refute preview["arguments"]["content"] =~ "synthetic@example.test"
    approve(next, record)

    assert {:ok, _} =
             review_call(next, write_payload("Contact: synthetic@example.test"),
               approval_id: record.id
             )

    assert Sandbox.inspect_state(c.sandbox).files["copy.txt"] == preview["arguments"]["content"]
  end

  test "key absence and audit failure prohibit review with no effect", c do
    old = Application.get_env(:ai_control, Cipher)
    Application.delete_env(:ai_control, Cipher)
    on_exit(fn -> Application.put_env(:ai_control, Cipher, old) end)
    assert {:error, :approval_unavailable} = review_call(c)
    assert Repo.aggregate(Approval, :count) == 0
    Application.put_env(:ai_control, Cipher, old)
    record = pending(%{c | key: Ecto.UUID.generate()})

    Repo.query!(
      "ALTER TABLE audit_events ADD CONSTRAINT reject_approval_audit CHECK (event_type NOT LIKE 'approval.%') NOT VALID",
      [],
      log: false
    )

    assert {:error, :audit_unavailable} =
             Approvals.decide(c.scope, record.id, :approve, record.revision)

    assert Repo.get!(Approval, record.id).status == "pending"
    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end

  test "dispatch audit failure rolls back consumption and charging before an effect", c do
    record = c |> pending() |> then(&approve(c, &1))

    Repo.query!(
      "ALTER TABLE audit_events ADD CONSTRAINT reject_approval_dispatch CHECK (event_type <> 'tool.dispatching') NOT VALID",
      [],
      log: false
    )

    assert {:error, :audit_unavailable} =
             review_call(c, write_payload(), approval_id: record.id)

    assert %{status: "invalidated", ciphertext: nil} = Repo.get!(Approval, record.id)
    assert Repo.get_by!(Execution, run_id: c.run.id).charged == false
    assert Workflows.evidence(Repo.get!(Run, c.run.id)).tool_calls == 0
    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end

  test "payload is absent from logs, audit, exports and broadcast metadata", c do
    Phoenix.PubSub.subscribe(
      AiControl.PubSub,
      "organizations:#{c.scope.organization.id}:approvals"
    )

    log = capture_log(fn -> pending(c) end)
    refute log =~ "Synthetic private"
    assert_receive :approvals_changed
    {:ok, filters} = Filters.parse(%{"action" => "review"})
    {:ok, page} = Audit.page_events(c.scope, filters)
    assert Enum.any?(page.events, &(&1.action == :review))
    events = Jason.encode!(Enum.map(page.events, &Serializer.event/1))
    refute events =~ "Synthetic private"
    refute events =~ "ciphertext"

    assert {:ok, {lines, _}} =
             Export.run(c.scope, filters, [], fn acc, batch -> {:ok, acc ++ batch} end)

    refute Enum.join(lines) =~ "Synthetic private"
    assert {:ok, %{approvals: [row]}} = Approvals.page(c.scope)
    assert row.ciphertext == nil
    record = Repo.one!(Approval)
    assert {:error, :approval_unavailable} = Cipher.decrypt(%{record | id: Ecto.UUID.generate()})
  end
end
