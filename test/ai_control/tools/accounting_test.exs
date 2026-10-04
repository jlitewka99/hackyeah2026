defmodule AiControl.Tools.AccountingTest do
  use AiControl.DataCase, async: false

  import AiControl.ToolsFixtures

  alias AiControl.{Budgets, Policies, Repo, Tools}
  alias AiControl.Tools.{Execution, Executions, Sandbox}

  setup do
    tool_fixture()
  end

  test "same key never repeats an effect, including after API key replacement", context do
    key = Ecto.UUID.generate()
    assert {:ok, result} = tool_call(context, "email.send", email(), idempotency_key: key)

    assert {:error, {:tool_execution_exists, %{execution_id: id, execution_status: "completed"}}} =
             tool_call(context, "email.send", email(), idempotency_key: key)

    assert id == result.execution_id

    assert {:error, {:idempotency_conflict, _}} =
             tool_call(context, "email.send", %{email() | "body" => "different"},
               idempotency_key: key
             )

    {_key, token} = AiControl.AgentsFixtures.key_fixture(context.scope, context.agent)
    {:ok, principal} = AiControl.ApiKeys.authenticate(token)

    assert {:error, {:tool_execution_exists, _}} =
             tool_call(%{context | principal: principal}, "email.send", email(),
               idempotency_key: key
             )

    assert length(Sandbox.inspect_state(context.sandbox).mailbox) == 1
    assert Enum.sum(Enum.map(Repo.all(Budgets.Workflow), & &1.calls)) == 1
  end

  test "contexts and callers cannot reset a claim or a quota", context do
    activate_tools(context.scope, %{"budgets" => %{"workflow" => %{"tool_calls" => 1}}})
    key = Ecto.UUID.generate()

    assert {:ok, _} =
             tool_call(context, "file.read", %{"path" => "report.txt"}, idempotency_key: key)

    assert {:error, :tool_budget_exceeded} = tool_call(context)

    :sys.replace_state(
      context.sandbox,
      &put_in(&1.contexts[context.agent.id], Ecto.UUID.generate())
    )

    assert {:error, {:tool_execution_exists, _}} =
             tool_call(context, "file.read", %{"path" => "report.txt"}, idempotency_key: key)

    assert {:error, :invalid_tool_request} =
             Tools.execute(
               context.principal,
               %{
                 "tool" => "file.read",
                 "arguments" => %{"path" => "report.txt"},
                 "workflow_id" => Ecto.UUID.generate()
               },
               idempotency_key: Ecto.UUID.generate()
             )
  end

  test "zero denies, null allows and lowering limits preserves counts", context do
    activate_tools(context.scope, %{"budgets" => %{"workflow" => %{"tool_calls" => 0}}})
    assert {:error, :tool_budget_exceeded} = tool_call(context)
    assert Repo.aggregate(Budgets.ToolExecution, :count) == 0
    activate_tools(context.scope, %{"budgets" => %{"workflow" => %{"tool_calls" => nil}}})
    assert {:ok, _} = tool_call(context)
    assert {:ok, _} = tool_call(context)
    activate_tools(context.scope, %{"budgets" => %{"workflow" => %{"tool_calls" => 1}}})
    assert {:error, :tool_budget_exceeded} = tool_call(context)
    assert Enum.sum(Enum.map(Repo.all(Budgets.Workflow), & &1.calls)) == 2
  end

  test "recovery retains dispatched charges and never runs pending operations", context do
    {:ok, request} =
      Tools.prepare(context.principal, %{"tool" => "email.send", "arguments" => email()})

    key = Ecto.UUID.generate()
    {:ok, pending} = Executions.claim(request, context.workflow, key)
    {:ok, dispatched} = Executions.claim(request, context.workflow, Ecto.UUID.generate())
    assert {:ok, _} = Executions.dispatch(dispatched, request)
    assert {:ok, :ok} = Executions.recover()
    assert Repo.get!(Execution, pending.id).status == "rejected"
    assert Repo.get!(Execution, dispatched.id).status == "uncertain"
    assert Enum.sum(Enum.map(Repo.all(Budgets.Workflow), & &1.calls)) == 1
    assert Sandbox.inspect_state(context.sandbox).mailbox == []

    assert {:error, {:tool_execution_exists, %{execution_status: "rejected"}}} =
             tool_call(context, "email.send", email(), idempotency_key: key)

    assert {:ok, :ok} = Executions.recover()
    assert Enum.sum(Enum.map(Repo.all(Budgets.Workflow), & &1.calls)) == 1
  end

  test "concurrent requests with the same key dispatch once", context do
    key = Ecto.UUID.generate()

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          tool_call(context, "email.send", email(), idempotency_key: key)
        end,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:tool_execution_exists, _}}, &1)) == 7
    assert length(Sandbox.inspect_state(context.sandbox).mailbox) == 1
  end

  test "expired deadline and cancelled owner deny before dispatch", context do
    {:ok, request} =
      Tools.prepare(context.principal, %{"tool" => "email.send", "arguments" => email()})

    {:ok, receipt} = Executions.claim(request, context.workflow, Ecto.UUID.generate())

    assert {:error, :tool_timeout} =
             Sandbox.run_prepared(
               context.sandbox,
               request,
               receipt,
               self(),
               System.monotonic_time(:millisecond) - 1
             )

    task = Task.async(fn -> :done end)
    pid = task.pid
    Task.await(task)

    assert {:error, :tool_cancelled} =
             Sandbox.run_prepared(
               context.sandbox,
               request,
               receipt,
               pid,
               System.monotonic_time(:millisecond) + 1000
             )

    assert Repo.get!(Execution, receipt.id).status == "pending"
    assert Repo.aggregate(Budgets.ToolExecution, :count) == 0
    assert Sandbox.inspect_state(context.sandbox).mailbox == []
  end

  test "tenants have independent key namespaces and counters", context do
    other = tool_fixture()
    key = Ecto.UUID.generate()

    assert {:ok, first} =
             tool_call(context, "file.read", %{"path" => "report.txt"}, idempotency_key: key)

    assert {:ok, second} =
             tool_call(other, "file.read", %{"path" => "report.txt"}, idempotency_key: key)

    refute first.execution_id == second.execution_id
    assert Repo.aggregate(Execution, :count) == 2
    {:ok, snapshot, _} = Policies.snapshot_for_models(context.principal, nil)

    assert {:error, :forbidden} =
             Budgets.consume_tool_call(
               context.principal,
               other.agent.id,
               snapshot,
               context.workflow,
               Ecto.UUID.generate()
             )
  end

  defp email, do: %{"recipient" => "demo@example.com", "subject" => "demo", "body" => "safe"}
end
