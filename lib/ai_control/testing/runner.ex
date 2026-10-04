defmodule AiControl.Testing.Runner do
  @moduledoc "Release-compatible child entry point. Only operator-selected isolated databases are accepted."
  alias AiControl.Gateway.Config
  alias AiControl.Testing.{Protocol, Suite}

  @spec main() :: no_return()
  def main do
    Logger.configure(level: :error)
    if System.get_env("AI_CONTROL_ISOLATED_RUNNER") != "1", do: System.halt(2)
    start_watchdog()
    AiControl.Release.migrate()
    {:ok, _} = Application.ensure_all_started(:ai_control)
    {:ok, _} = Supervisor.start_child(AiControl.Supervisor, AiControl.Testing.State)
    config = Keyword.put(Config.get(), :guards, Config.guard_modules())

    controlled =
      Keyword.merge(config,
        provider: AiControl.Testing.Provider,
        tokenizer: AiControl.Testing.Tokenizer,
        models: %{"synthetic:controlled" => String.duplicate("a", 64)}
      )

    Application.put_env(:ai_control, Config, controlled)
    {:ok, server} = Bandit.start_link(plug: AiControlWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    origin = "http://127.0.0.1:#{port}"

    emit = fn row ->
      {:ok, safe} = Protocol.case_result(row)
      IO.puts("AI_CONTROL_CASE " <> Jason.encode!(safe))
    end

    suite = System.fetch_env!("AI_CONTROL_TEST_SUITE")
    mode = System.fetch_env!("AI_CONTROL_TEST_MODE")

    result =
      case {suite, mode} do
        {"gateway.v1", "controlled"} ->
          Suite.run(origin, emit)
          :ok

        {"gateway.v1", "live"} ->
          Suite.run(origin, emit)
          Application.put_env(:ai_control, Config, config)
          Suite.live(origin, emit)

        {"semantic-pl.v1", "live"} ->
          Application.put_env(:ai_control, Config, config)
          Suite.live(origin, emit)

        _ ->
          {:error, :invalid_result}
      end

    case result do
      :ok ->
        IO.puts("AI_CONTROL_DONE")
        System.halt(0)

      {:error, :runner_unavailable} ->
        IO.puts("AI_CONTROL_UNAVAILABLE")
        System.halt(3)

      _ ->
        System.halt(4)
    end
  rescue
    _ -> System.halt(4)
  end

  defp start_watchdog do
    # EOF closes the child when its parent dies. A stalled parent also loses its lease.
    parent = self()
    watcher = spawn(fn -> lease(parent) end)

    spawn(fn ->
      Stream.repeatedly(fn -> IO.gets("") end)
      |> Enum.reduce_while(nil, fn
        "ping\n", _ ->
          send(watcher, :lease)
          {:cont, nil}

        _, _ ->
          System.halt(5)
          {:halt, nil}
      end)
    end)

    spawn(__MODULE__, :deadline, [parent, System.monotonic_time(:millisecond) + 7_200_000])
  end

  defp lease(parent) do
    ref = Process.monitor(parent)

    receive do
      :lease ->
        Process.demonitor(ref, [:flush])
        lease(parent)

      {:DOWN, ^ref, :process, _, _} ->
        System.halt(5)
    after
      30_000 -> System.halt(5)
    end
  end

  @doc false
  @spec deadline(pid(), integer()) :: no_return()
  def deadline(parent, deadline) do
    ref = Process.monitor(parent)

    receive do
      {:DOWN, ^ref, :process, _, _} -> System.halt(5)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> System.halt(6)
    end
  end
end
