defmodule AiControl.Organizations.ConcurrencyTest do
  use ExUnit.Case, async: false

  import AiControl.AccountsFixtures
  import AiControl.OrganizationsFixtures
  import Ecto.Query

  alias AiControl.Accounts.User
  alias AiControl.Organizations
  alias AiControl.Organizations.{Invitations, Membership, Organization}
  alias AiControl.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @timeout 10_000

  setup do
    scope = Sandbox.unboxed_run(Repo, fn -> organization_fixture() end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        ids =
          Repo.all(
            from(m in Membership,
              where: m.organization_id == ^scope.organization.id,
              select: m.user_id
            )
          )

        Repo.delete!(scope.organization)

        Repo.delete_all(from(u in User, where: u.id in ^Enum.uniq([scope.user.id | ids])),
          log: false
        )
      end)
    end)

    %{scope: scope}
  end

  test "simultaneous invitation submissions create exactly one account and membership", %{
    scope: scope
  } do
    {invitation, token} = Sandbox.unboxed_run(Repo, fn -> invitation_fixture(scope) end)

    attrs = %{
      "password" => valid_user_password(),
      "password_confirmation" => valid_user_password()
    }

    results =
      concurrent(scope.organization.id, [
        fn -> Invitations.accept(token, nil, attrs) end,
        fn -> Invitations.accept(token, nil, attrs) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :invalid_invitation} in results

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(from(u in User, where: u.email == ^invitation.email), :count) == 1

      assert Repo.aggregate(
               from(m in Membership, where: m.organization_id == ^scope.organization.id),
               :count
             ) == 1
    end)
  end

  test "competing ownership transfers produce one superadmin", %{scope: scope} do
    {owner, first, second} =
      Sandbox.unboxed_run(Repo, fn ->
        {member_fixture(scope, :superadmin), member_fixture(scope, :admin),
         member_fixture(scope, :admin)}
      end)

    results =
      concurrent(scope.organization.id, [
        fn -> Organizations.transfer_superadmin(owner.scope, first.membership.id) end,
        fn -> Organizations.transfer_superadmin(owner.scope, second.membership.id) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :forbidden} in results

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(
               from(m in Membership,
                 where: m.organization_id == ^scope.organization.id and m.role == :superadmin
               ),
               :count
             ) == 1
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
