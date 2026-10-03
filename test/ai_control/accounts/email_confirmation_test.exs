defmodule AiControl.Accounts.EmailConfirmationTest do
  use ExUnit.Case, async: false

  import AiControl.AccountsFixtures
  import Ecto.Query

  alias AiControl.Accounts
  alias AiControl.Accounts.{User, UserToken}
  alias AiControl.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @timeout 10_000

  setup do
    # Separate connections need committed fixtures, rather than a shared sandbox.
    user = Sandbox.unboxed_run(Repo, fn -> unconfirmed_user_fixture() end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(u in User, where: u.id == ^user.id), log: false)
      end)
    end)

    %{user: user}
  end

  test "concurrent uses of the same token succeed exactly once", %{user: user} do
    {token, email} = change_token(user)
    results = confirm_concurrently(user, [token, token])

    assert [{:ok, changed_user}] = Enum.filter(results, &match?({:ok, %User{}}, &1))
    assert {:error, :transaction_aborted} in results
    assert changed_user.email == email
    assert_consumed(user, changed_user)
  end

  test "concurrent tokens for competing email changes succeed exactly once", %{user: user} do
    {first_token, first_email} = change_token(user)
    {second_token, second_email} = change_token(user)
    results = confirm_concurrently(user, [first_token, second_token])

    assert [{:ok, changed_user}] = Enum.filter(results, &match?({:ok, %User{}}, &1))
    assert {:error, :transaction_aborted} in results
    assert changed_user.email in [first_email, second_email]
    assert_consumed(user, changed_user)
  end

  defp change_token(user) do
    Sandbox.unboxed_run(Repo, fn ->
      email = unique_user_email()

      {token, record} =
        UserToken.build_email_token(%{user | email: email}, "change:#{user.email}")

      Repo.insert!(record, log: false)
      {token, email}
    end)
  end

  defp confirm_concurrently(user, tokens) do
    parent = self()
    barrier = make_ref()

    holder =
      start_database_task(:email_lock, fn ->
        Repo.transact(fn ->
          Repo.one!(from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE"), log: false)
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
      tokens
      |> Enum.with_index()
      |> Enum.map(fn {token, index} ->
        start_database_task({:email_confirmation, index}, fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()", [], log: false)
          send(parent, {:connection, barrier, self(), backend_pid})
          Accounts.update_user_email(user, token)
        end)
      end)

    try do
      backend_pids =
        Enum.map(workers, fn %{pid: pid} ->
          assert_receive {:connection, ^barrier, ^pid, backend_pid}, @timeout
          backend_pid
        end)

      # Both requests must be waiting in PostgreSQL before the lock is released.
      # This reproduces the old race deterministically, including on a single CPU.
      Sandbox.unboxed_run(Repo, fn ->
        await_lock_waiters(backend_pids, System.monotonic_time(:millisecond) + 5_000)
      end)
    after
      send(holder.pid, {:release, barrier})
    end

    assert await_result(holder) == {:ok, :released}
    Enum.map(workers, &await_result/1)
  end

  defp start_database_task(id, fun) do
    parent = self()

    task =
      {Task,
       fn ->
         result = Sandbox.unboxed_run(Repo, fun)
         send(parent, {:result, self(), result})
       end}

    pid = start_supervised!(Supervisor.child_spec(task, id: id))
    %{pid: pid, monitor: Process.monitor(pid)}
  end

  defp await_lock_waiters(backend_pids, deadline) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE pid = ANY($1) AND wait_event_type = 'Lock'",
        [backend_pids],
        log: false
      )

    if count != length(backend_pids) do
      assert System.monotonic_time(:millisecond) < deadline,
             "both email confirmations must wait on a database lock"

      await_lock_waiters(backend_pids, deadline)
    end
  end

  defp await_result(%{pid: pid, monitor: monitor}) do
    assert_receive {:result, ^pid, result}, @timeout
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @timeout
    result
  end

  defp assert_consumed(user, changed_user) do
    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get!(User, user.id).email == changed_user.email
      refute Repo.exists?(from(t in UserToken, where: t.user_id == ^user.id))
    end)
  end
end
