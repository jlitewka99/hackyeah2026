defmodule AiControl.Budgets.ConcurrencyTest do
  use ExUnit.Case, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures
  import Ecto.Query

  alias AiControl.Audit.Event
  alias AiControl.{Budgets, Policies, Repo}
  alias AiControl.Budgets.Bucket
  alias AiControl.Organizations.Organization
  alias AiControl.Policies.{Activation, Set, Version}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    context =
      Sandbox.unboxed_run(Repo, fn ->
        scope = organization_fixture()
        agent = agent_fixture(scope)
        other = agent_fixture(scope)

        %{
          scope: scope,
          agent: agent,
          principal: principal_fixture(scope, agent),
          other: principal_fixture(scope, other)
        }
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        set = Repo.get_by!(Set, organization_id: context.scope.organization.id)
        Repo.update_all(from(s in Set, where: s.id == ^set.id), set: [active_version_id: nil])
        Repo.delete_all(from(a in Activation, where: a.set_id == ^set.id))
        Repo.delete_all(from(v in Version, where: v.set_id == ^set.id))

        Repo.delete_all(
          from(e in Event,
            where: e.organization_id == ^context.scope.organization.id
          ),
          log: false
        )

        Repo.delete!(context.scope.organization)
        Repo.delete!(context.scope.user)
      end)
    end)

    context
  end

  test "competing agents cannot over-reserve the organization", context do
    {first, second} = receipts(context, %{"organization" => %{"tokens_per_hour" => 5000}}, true)

    results =
      concurrent(context, [
        fn -> Budgets.reserve(first, 2000, 2000) end,
        fn -> Budgets.reserve(second, 2000, 2000) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:token_budget_exceeded, _}}, &1)) == 1
    assert_balance(context, 4000)
  end

  test "agent limit rolls back the other level under contention", context do
    {first, second} =
      receipts(
        context,
        %{
          "organization" => %{"tokens_per_hour" => 9000},
          "agent" => %{"tokens_per_hour" => 5000}
        },
        false
      )

    results =
      concurrent(context, [
        fn -> Budgets.reserve(first, 2000, 2000) end,
        fn -> Budgets.reserve(second, 2000, 2000) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert_balance(context, 4000)
  end

  test "request and workflow limits admit one simultaneous caller", context do
    snapshot =
      Sandbox.unboxed_run(Repo, fn ->
        activate_gateway_policy(context.scope, %{
          "budgets" => %{
            "organization" => %{"requests_per_hour" => 1},
            "workflow" => %{"tool_calls" => 1}
          }
        })

        {:ok, snapshot, _} = Policies.snapshot_for_models(context.principal, nil)
        snapshot
      end)

    results =
      concurrent(
        context,
        for _ <- 1..2 do
          fn ->
            Budgets.admit(
              context.principal,
              nil,
              "deepseek-flash",
              snapshot,
              Ecto.UUID.generate()
            )
          end
        end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    workflow = Ecto.UUID.generate()

    results =
      concurrent(
        context,
        for _ <- 1..2 do
          fn ->
            Budgets.consume_tool_call(
              context.principal,
              nil,
              snapshot,
              workflow,
              Ecto.UUID.generate()
            )
          end
        end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :tool_budget_exceeded} in results
  end

  defp receipts(context, limits, other?) do
    Sandbox.unboxed_run(Repo, fn ->
      activate_gateway_policy(context.scope, %{"budgets" => limits})
      {:ok, snapshot, _} = Policies.snapshot_for_models(context.principal, nil)

      {:ok, first} =
        Budgets.admit(context.principal, nil, "deepseek-flash", snapshot, Ecto.UUID.generate())

      principal = if other?, do: context.other, else: context.principal

      {:ok, second} =
        Budgets.admit(principal, nil, "deepseek-flash", snapshot, Ecto.UUID.generate())

      {first, second}
    end)
  end

  defp assert_balance(context, amount) do
    Sandbox.unboxed_run(Repo, fn ->
      bucket =
        Repo.get_by!(Bucket,
          organization_id: context.scope.organization.id,
          level: "organization"
        )

      assert bucket.reserved == amount
      assert bucket.tokens == 0
    end)
  end

  defp concurrent(context, callbacks) do
    parent = self()
    barrier = make_ref()

    holder =
      worker(:holder, fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(o in Organization,
              where: o.id == ^context.scope.organization.id,
              lock: "FOR UPDATE"
            )
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
      |> Enum.map(fn {callback, index} ->
        worker({:worker, index}, fn ->
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

      Sandbox.unboxed_run(Repo, fn ->
        wait_for_locks(backends, System.monotonic_time(:millisecond) + 5000)
      end)
    after
      send(elem(holder, 0), {:release, barrier})
    end

    assert result(holder) == {:ok, :ok}
    Enum.map(workers, &result/1)
  end

  defp worker(id, callback) do
    parent = self()

    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Task, fn -> send(parent, {:result, self(), Sandbox.unboxed_run(Repo, callback)}) end},
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
