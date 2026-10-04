defmodule AiControl.Approvals.ConcurrencyTest do
  use ExUnit.Case, async: false

  import AiControl.ApprovalsFixtures
  import Ecto.Query

  alias AiControl.{Approvals, Repo, Workflows}
  alias AiControl.Approvals.Approval
  alias AiControl.Organizations.Organization
  alias AiControl.Policies.{Activation, Set, Version}
  alias AiControl.Workflows.Run
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(Repo, :auto)
    c = approval_fixture()

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

      Repo.delete_all(from(a in Approval, where: a.organization_id == ^c.run.organization_id))
      Repo.delete!(c.scope.organization)
      Repo.delete!(c.scope.user)
      Sandbox.mode(Repo, :manual)
    end)

    c
  end

  test "separate connections permit one resume and one dispatch", c do
    record = c |> pending() |> then(&approve(c, &1))

    results =
      concurrent(
        c,
        Enum.map(1..2, fn _ ->
          fn -> review_call(c, write_payload(), approval_id: record.id) end
        end)
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :approval_used} in results
    assert Repo.get!(Approval, record.id).status == "consumed"
    run = Repo.get!(Run, c.run.id)
    assert run.calls == 1
    assert Workflows.evidence(run).tool_calls == 1

    assert Repo.aggregate(
             from(e in AiControl.Audit.Event,
               where:
                 e.organization_id == ^c.run.organization_id and
                   e.event_type == "tool.dispatching"
             ),
             :count
           ) == 1
  end

  test "concurrent initial chat attempts retain one logical operation and no reservation", c do
    results = concurrent(c, Enum.map(1..2, fn _ -> fn -> chat(c) end end))
    assert Enum.all?(results, &match?({:error, {:approval_required, _}}, &1))

    assert results
           |> Enum.map(fn {:error, {:approval_required, data}} -> data.approval_id end)
           |> Enum.uniq()
           |> length() == 1

    assert Repo.aggregate(
             from(a in Approval, where: a.organization_id == ^c.run.organization_id),
             :count
           ) == 1

    assert %{calls: 1, reserved_tokens: 0} = Repo.get!(Run, c.run.id)
  end

  test "overlapping preparations reject changed input or prepared payload", c do
    original = write_payload()
    changed = write_payload("A different synthetic payload")

    for {second_input, second_payload} <- [{changed, changed}, {original, changed}] do
      opts = [run_context: c.reference, idempotency_key: Ecto.UUID.generate()]

      tickets =
        Enum.map([original, second_input], fn input ->
          assert {:ok, ticket} =
                   Approvals.prepare(
                     c.principal,
                     "tool",
                     input,
                     c.policy,
                     Ecto.UUID.generate(),
                     opts
                   )

          assert ticket.id == nil
          ticket
        end)

      results =
        concurrent(
          c,
          Enum.zip_with(tickets, [original, second_payload], fn ticket, payload ->
            fn -> Approvals.gate(ticket, c.principal, payload, c.policy, []) end
          end)
        )

      assert Enum.count(results, &match?({:error, {:approval_required, _}}, &1)) == 1
      assert {:error, :approval_conflict} in results
      record = Repo.get_by!(Approval, idempotency_key: opts[:idempotency_key])
      assert %{status: "invalidated", ciphertext: nil} = record
    end

    assert %{calls: 0} = Repo.get!(Run, c.run.id)
    refute Map.has_key?(AiControl.Tools.Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end

  test "competing administrator decisions honor the expected revision", c do
    record = pending(c)

    results =
      concurrent(c, [
        fn -> Approvals.decide(c.scope, record.id, :approve, record.revision) end,
        fn -> Approvals.decide(c.scope, record.id, :reject, record.revision) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :approval_conflict} in results
    assert Repo.get!(Approval, record.id).revision == 2
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
