defmodule AiControl.Policies.ConcurrencyTest do
  use ExUnit.Case, async: false

  import AiControl.OrganizationsFixtures
  import Ecto.Query

  alias AiControl.{Policies, Repo}
  alias AiControl.Policies.{Activation, Configuration, Set, Version}
  alias Ecto.Adapters.SQL.Sandbox

  @timeout 10_000

  test "competing activations with one revision produce exactly one committed change" do
    scope = Sandbox.unboxed_run(Repo, fn -> organization_fixture() end)
    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> cleanup(scope) end) end)

    {current, versions} =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, current} = Policies.current(scope)

        versions =
          Enum.map(~w(relaxed strict), fn profile ->
            {:ok, version} =
              Policies.create_version(scope, Map.put(Configuration.default(), "profile", profile))

            version
          end)

        {current, versions}
      end)

    parent = self()
    barrier = make_ref()

    holder =
      worker(:holder, fn ->
        Repo.transact(fn ->
          Repo.one!(
            from(o in AiControl.Organizations.Organization,
              where: o.id == ^scope.organization.id,
              lock: "FOR UPDATE"
            )
          )

          send(parent, {:locked, barrier})

          receive do
            {:release, ^barrier} -> {:ok, :released}
          after
            @timeout -> {:error, :timeout}
          end
        end)
      end)

    assert_receive {:locked, ^barrier}, @timeout

    workers =
      Enum.map(versions, fn version ->
        worker(version.id, fn ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()", [], log: false)
          send(parent, {:backend, self(), backend})
          Policies.activate(scope, version.id, current.set.revision)
        end)
      end)

    try do
      backends =
        Enum.map(workers, fn {pid, _} ->
          assert_receive {:backend, ^pid, backend}, @timeout
          backend
        end)

      Sandbox.unboxed_run(Repo, fn ->
        wait_for_locks(backends, System.monotonic_time(:millisecond) + 5_000)
      end)
    after
      send(elem(holder, 0), {:release, barrier})
    end

    assert result(holder) == {:ok, :released}
    results = Enum.map(workers, &result/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :stale_policy} in results

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(from(a in Activation, where: a.set_id == ^current.set.id), :count) ==
               1

      assert Repo.aggregate(
               from(e in AiControl.Audit.Event,
                 where:
                   e.organization_id == ^scope.organization.id and
                     e.event_type == "policy.activated"
               ),
               :count
             ) == 1
    end)
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
    assert_receive {:result, ^pid, result}, @timeout
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @timeout
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

  defp cleanup(scope) do
    set = Repo.get_by!(Set, organization_id: scope.organization.id)
    Repo.update!(Ecto.Changeset.change(set, active_version_id: nil))
    Repo.delete_all(from(a in Activation, where: a.set_id == ^set.id), log: false)
    Repo.delete_all(from(v in Version, where: v.set_id == ^set.id), log: false)

    Repo.delete_all(
      from(e in AiControl.Audit.Event, where: e.organization_id == ^scope.organization.id),
      log: false
    )

    Repo.delete!(scope.organization)
    Repo.delete!(scope.user)
  end
end
