defmodule AiControl.Workflows.ConcurrencyTest do
  use ExUnit.Case, async: false

  import AiControl.AgentsFixtures
  import AiControl.WorkflowsFixtures
  import Ecto.Query

  alias AiControl.{Budgets, Repo, Workflows}
  alias AiControl.Organizations.Organization
  alias AiControl.Policies.{Activation, Set, Version}
  alias AiControl.Workflows.{Operation, Run, Runtime}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(Repo, :auto)
    c = workflow_fixture(%{"max_tokens" => 20, "max_calls" => 3})

    on_exit(fn ->
      case Registry.lookup(AiControl.Workflows.Registry, {c.run.organization_id, c.run.id}) do
        [{pid, _}] ->
          DynamicSupervisor.terminate_child(AiControl.Workflows.DynamicSupervisor, pid)

        _ ->
          :ok
      end

      :sys.get_state(AiControl.Workflows.Manager)
      set = Repo.get_by!(Set, organization_id: c.run.organization_id)
      Repo.update_all(from(s in Set, where: s.id == ^set.id), set: [active_version_id: nil])
      Repo.delete_all(from(a in Activation, where: a.set_id == ^set.id))
      Repo.delete_all(from(v in Version, where: v.set_id == ^set.id))

      Repo.delete_all(
        from(e in AiControl.Audit.Event, where: e.organization_id == ^c.run.organization_id)
      )

      Repo.delete!(c.scope.organization)
      Repo.delete!(c.scope.user)
      Sandbox.mode(Repo, :manual)
    end)

    c
  end

  test "competing reservations cannot exceed the root even without hourly caps", c do
    receipts =
      for i <- 1..2 do
        {:ok, ctx} = Workflows.admit(c.reference, c.policy, "chat", %{"index" => i})
        operation = Repo.get!(Operation, ctx.operation_id)

        {:ok, receipt} =
          Budgets.admit(
            c.principal,
            nil,
            "deepseek-flash",
            c.policy,
            operation.request_id,
            DateTime.utc_now(),
            ctx
          )

        receipt
      end

    results =
      concurrent(
        c,
        Enum.map(receipts, fn receipt -> fn -> Budgets.reserve(receipt, 12, 4) end end)
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :workflow_limit_exceeded} in results
    run = Repo.get!(Run, c.run.id)
    assert {run.status, run.reserved_tokens} == {"limit_exceeded", 16}
  end

  test "competing delegations share a single operation allowance", c do
    {:ok, ctx} = Workflows.admit(c.reference, c.policy, "chat", %{})
    Workflows.finish(ctx)
    other = agent_fixture(c.scope)

    callbacks =
      for _ <- 1..3 do
        fn ->
          Workflows.delegate(
            c.principal,
            c.run.id,
            c.participant.id,
            %{"target_agent_id" => other.id},
            Ecto.UUID.generate()
          )
        end
      end

    results = concurrent(c, callbacks)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 2
    assert Repo.get!(Run, c.run.id).calls == 3
  end

  test "runtime crash and startup recovery interrupt without replenishing counters", c do
    {:ok, _} = Workflows.admit(c.reference, c.policy, "chat", %{})
    [{pid, _}] = Registry.lookup(AiControl.Workflows.Registry, {c.run.organization_id, c.run.id})
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    :sys.get_state(AiControl.Workflows.Manager)
    assert Repo.get!(Run, c.run.id).status == "interrupted"
    assert Repo.get!(Run, c.run.id).calls == 1
    assert {:error, :workflow_terminal} = Workflows.resolve(c.principal, c.policy, c.reference)
    refute Runtime.present?(c.run.organization_id, c.run.id)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Run, c.run.id), status: "running", finished_at: nil)
    )

    assert :ok = Workflows.recover()
    assert Repo.get!(Run, c.run.id).status == "interrupted"
    assert Repo.get!(Run, c.run.id).calls == 1
  end

  defp concurrent(c, callbacks) do
    parent = self()
    barrier = make_ref()

    holder =
      worker(:holder, fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(o in Organization, where: o.id == ^c.run.organization_id, lock: "FOR UPDATE")
          )

          send(parent, {:locked, barrier})

          receive do
            {:release, ^barrier} -> :ok
          after
            10_000 -> raise "barrier timeout"
          end
        end)
      end)

    assert_receive {:locked, ^barrier}, 10_000

    workers =
      callbacks
      |> Enum.with_index()
      |> Enum.map(fn {callback, i} ->
        worker({:worker, i}, fn ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()", [], log: false)
          send(parent, {:backend, self(), backend})
          callback.()
        end)
      end)

    try do
      backends =
        Enum.map(workers, fn {pid, _} ->
          assert_receive {:backend, ^pid, backend}, 10_000
          backend
        end)

      wait_for_locks(backends, System.monotonic_time(:millisecond) + 5000)
    after
      send(elem(holder, 0), {:release, barrier})
    end

    assert result(holder) == {:ok, :ok}
    Enum.map(workers, &result/1)
  end

  defp worker(id, fun) do
    parent = self()

    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Task, fn -> send(parent, {:result, self(), Sandbox.unboxed_run(Repo, fun)}) end},
          id: id
        )
      )

    {pid, Process.monitor(pid)}
  end

  defp result({pid, ref}) do
    assert_receive {:result, ^pid, result}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
    result
  end

  defp wait_for_locks(backends, deadline) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE pid = ANY($1) AND wait_event_type = 'Lock'",
        [backends],
        log: false
      )

    if count != length(backends) do
      assert System.monotonic_time(:millisecond) < deadline
      wait_for_locks(backends, deadline)
    end
  end
end
