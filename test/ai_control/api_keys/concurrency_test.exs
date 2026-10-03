defmodule AiControl.ApiKeys.ConcurrencyTest do
  use ExUnit.Case, async: false

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures
  import Ecto.Query

  alias AiControl.Accounts.User
  alias AiControl.{ApiKeys, Organizations, Repo}
  alias AiControl.ApiKeys.ApiKey
  alias AiControl.Organizations.Organization
  alias Ecto.Adapters.SQL.Sandbox

  @timeout 10_000

  setup do
    {scope, agent, key, token} =
      Sandbox.unboxed_run(Repo, fn ->
        scope = organization_fixture()
        agent = agent_fixture(scope)
        {key, token} = key_fixture(scope, agent)
        {scope, agent, key, token}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from(e in AiControl.Audit.Event, where: e.organization_id == ^scope.organization.id),
          log: false
        )

        Repo.delete!(scope.organization)
        Repo.delete_all(from(u in User, where: u.id == ^scope.user.id), log: false)
      end)
    end)

    %{scope: scope, agent: agent, key: key, token: token}
  end

  test "competing rotations create exactly one replacement and revoke the original", %{
    scope: scope,
    key: key,
    token: token
  } do
    results =
      concurrent(scope.organization.id, [
        fn -> ApiKeys.rotate_key(scope, key.id) end,
        fn -> ApiKeys.rotate_key(scope, key.id) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :inactive_key} in results
    [{:ok, {replacement, replacement_token}}] = Enum.filter(results, &match?({:ok, _}, &1))

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(
               from(k in ApiKey, where: k.organization_id == ^scope.organization.id),
               :count
             ) == 2

      assert {:error, :invalid_api_key} = ApiKeys.authenticate(token)
      assert {:ok, %{api_key_id: id}} = ApiKeys.authenticate(replacement_token)
      assert id == replacement.id
    end)
  end

  test "revocation racing rotation cannot restore the original", %{
    scope: scope,
    key: key,
    token: token
  } do
    results =
      concurrent(scope.organization.id, [
        fn -> ApiKeys.revoke_key(scope, key.id) end,
        fn -> ApiKeys.rotate_key(scope, key.id) end
      ])

    Sandbox.unboxed_run(Repo, fn ->
      assert {:error, :invalid_api_key} = ApiKeys.authenticate(token)
      assert Repo.get!(ApiKey, key.id).revoked_at

      assert Repo.aggregate(
               from(k in ApiKey, where: k.organization_id == ^scope.organization.id),
               :count
             ) in [1, 2]

      assert Enum.any?(results, &match?({:ok, _}, &1))
    end)
  end

  test "organization suspension racing issuance leaves every credential unusable", %{
    scope: scope,
    agent: agent,
    token: token
  } do
    results =
      concurrent(scope.organization.id, [
        fn -> Organizations.set_status(scope, :suspended) end,
        fn -> ApiKeys.create_key(scope, agent.id, %{label: "Concurrent key"}) end
      ])

    Sandbox.unboxed_run(Repo, fn ->
      assert {:error, :invalid_api_key} = ApiKeys.authenticate(token)

      for {:ok, {_key, issued}} <- results do
        assert {:error, :invalid_api_key} = ApiKeys.authenticate(issued)
      end

      assert Repo.get!(Organization, scope.organization.id).status == :suspended
    end)
  end

  defp concurrent(organization_id, callbacks) do
    parent = self()
    barrier = make_ref()

    holder =
      database_task(:holder, fn ->
        Repo.transact(fn ->
          Repo.one!(from(o in Organization, where: o.id == ^organization_id, lock: "FOR UPDATE"))
          send(parent, {:locked, barrier})

          receive do
            {:release, ^barrier} -> {:ok, :released}
          after
            @timeout -> {:error, :lock_timeout}
          end
        end)
      end)

    assert_receive {:locked, ^barrier}, @timeout

    workers =
      callbacks
      |> Enum.with_index()
      |> Enum.map(fn {callback, index} ->
        database_task({:worker, index}, fn ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()", [], log: false)
          send(parent, {:backend, barrier, self(), backend})
          callback.()
        end)
      end)

    try do
      backends =
        Enum.map(workers, fn %{pid: pid} ->
          assert_receive {:backend, ^barrier, ^pid, backend}, @timeout
          backend
        end)

      Sandbox.unboxed_run(Repo, fn ->
        await_waiters(backends, System.monotonic_time(:millisecond) + 5_000)
      end)
    after
      send(holder.pid, {:release, barrier})
    end

    assert result(holder) == {:ok, :released}
    Enum.map(workers, &result/1)
  end

  defp database_task(id, callback) do
    parent = self()
    task = {Task, fn -> send(parent, {:result, self(), Sandbox.unboxed_run(Repo, callback)}) end}
    pid = start_supervised!(Supervisor.child_spec(task, id: id))
    %{pid: pid, monitor: Process.monitor(pid)}
  end

  defp await_waiters(backends, deadline) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE pid = ANY($1) AND wait_event_type = 'Lock'",
        [backends],
        log: false
      )

    if count != length(backends) do
      assert System.monotonic_time(:millisecond) < deadline
      await_waiters(backends, deadline)
    end
  end

  defp result(%{pid: pid, monitor: monitor}) do
    assert_receive {:result, ^pid, result}, @timeout
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @timeout
    result
  end
end
