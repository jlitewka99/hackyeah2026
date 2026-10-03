defmodule AiControl.Accounts.LoginLimiterTest do
  use ExUnit.Case, async: false

  alias AiControl.Accounts.LoginLimiter
  alias AiControl.LoginLimiterBackend

  @window to_timeout(minute: 15)

  setup do
    pid = start_supervised!(LoginLimiterBackend)
    %{owner: pid, backend: LoginLimiterBackend}
  end

  test "email limit normalizes case and whitespace and expires at the boundary", %{
    backend: backend
  } do
    for i <- 1..5,
        do: assert(:ok == LoginLimiter.check({127, 0, 0, i}, "User@example.com", backend))

    assert {:error, 900} = LoginLimiter.check({127, 0, 0, 6}, "  USER@example.com  ", backend)

    # Hammer owns its clock. Set the stored deadline to exercise each boundary
    # against the real backend deterministically, without sleeping or mocking it.
    key = {:email, :crypto.hash(:sha256, "user@example.com")}
    set_deadline(backend, key, Hammer.ETS.now() + 1000)
    assert {:error, 1} = LoginLimiter.check({127, 0, 0, 7}, "user@example.com", backend)
    set_deadline(backend, key, Hammer.ETS.now() - 1)
    assert :ok = LoginLimiter.check({127, 0, 0, 8}, "user@example.com", backend)
    assert backend.get(key, @window) == 1
  end

  test "IP limit applies across emails and token attempts", %{backend: backend} do
    ip = {127, 0, 0, 1}
    for i <- 1..20, do: assert(:ok == LoginLimiter.check(ip, "user#{i}@example.com", backend))
    assert {:error, 900} = LoginLimiter.check(ip, nil, backend)
    assert :ok = LoginLimiter.check({127, 0, 0, 2}, nil, backend)
  end

  test "denied email attempts still consume the peer IP budget", %{backend: backend} do
    ip = {127, 0, 0, 1}
    for _ <- 1..5, do: assert(:ok == LoginLimiter.check(ip, "same@example.com", backend))

    for _ <- 1..15,
        do: assert({:error, 900} == LoginLimiter.check(ip, "same@example.com", backend))

    assert {:error, 900} = LoginLimiter.check(ip, "different@example.com", backend)
    assert backend.get({:email, :crypto.hash(:sha256, "different@example.com")}, @window) == 0
  end

  test "concurrent requests cannot pass the account limit", %{backend: backend} do
    results =
      concurrent_checks(fn i ->
        LoginLimiter.check({127, 0, 0, i}, "same@example.com", backend)
      end)

    assert Enum.count(results, &(&1 == :ok)) == 5
    assert Enum.count(results, &match?({:error, _}, &1)) == 25
  end

  test "concurrent requests cannot pass the IP limit", %{backend: backend} do
    results = concurrent_checks(fn _ -> LoginLimiter.check({127, 0, 0, 1}, nil, backend) end)
    assert Enum.count(results, &(&1 == :ok)) == 20
    assert Enum.count(results, &match?({:error, _}, &1)) == 10
  end

  test "supervised cleanup removes expired fingerprints without retaining emails", %{
    backend: backend,
    owner: owner
  } do
    assert :ok = LoginLimiter.check({127, 0, 0, 1}, "secret@example.com", backend)
    refute inspect(:ets.tab2list(backend)) =~ "secret@example.com"

    for {key, _count, _expires} <- :ets.tab2list(backend),
        do: set_deadline(backend, key, Hammer.ETS.now() - 1)

    send(owner, :clean)
    _ = :sys.get_state(owner)
    assert :ets.tab2list(backend) == []
  end

  defp set_deadline(table, key, expires_at), do: :ets.update_element(table, key, {3, expires_at})

  defp concurrent_checks(fun) do
    1..30
    |> Task.async_stream(fun, timeout: :infinity)
    |> Enum.map(fn {:ok, result} -> result end)
  end
end
