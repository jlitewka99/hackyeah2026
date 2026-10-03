defmodule AiControl.Gateway.Slots do
  @moduledoc "Monitored leases with supervised workers; overload never queues."
  use GenServer

  alias AiControl.Gateway.Config

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def run(kind, timeout, callback) do
    with {:ok, lease} <- GenServer.call(__MODULE__, {:acquire, kind}) do
      try do
        run_worker(lease, timeout, callback)
      after
        GenServer.call(__MODULE__, {:release, lease})
      end
    end
  end

  defp run_worker(lease, timeout, callback) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(AiControl.Gateway.Tasks, fn ->
        # Cancellation can happen before the slot manager attaches this worker.
        ref = Process.monitor(owner)

        receive do
          :run ->
            Process.demonitor(ref, [:flush])
            safe(callback)

          {:DOWN, ^ref, :process, ^owner, _} ->
            {:error, :upstream_unavailable}
        end
      end)

    case GenServer.call(__MODULE__, {:attach, lease, task.pid}) do
      :ok ->
        send(task.pid, :run)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> {:error, :upstream_timeout}
        end

      _ ->
        Task.shutdown(task, :brutal_kill)
        {:error, :upstream_unavailable}
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       leases: %{},
       limits:
         Keyword.get(opts, :limits, %{
           llm: Config.get(:llm_slots),
           guard: Config.get(:guard_slots)
         })
     }}
  end

  @impl true
  def handle_call({:acquire, kind}, {owner, _}, state) do
    used = Enum.count(state.leases, fn {_, lease} -> lease.kind == kind end)

    if used < Map.fetch!(state.limits, kind) do
      ref = Process.monitor(owner)
      lease = %{kind: kind, owner: owner, worker: nil, worker_ref: nil}
      {:reply, {:ok, ref}, put_in(state.leases[ref], lease)}
    else
      {:reply, {:error, {:capacity_exceeded, 1}}, state}
    end
  end

  def handle_call({:attach, ref, worker}, {owner, _}, state) do
    case state.leases[ref] do
      %{owner: ^owner, worker: nil} = lease ->
        lease = %{lease | worker: worker, worker_ref: Process.monitor(worker)}
        {:reply, :ok, put_in(state.leases[ref], lease)}

      _ ->
        {:reply, :error, state}
    end
  end

  def handle_call({:release, ref}, _, state), do: {:reply, :ok, release(state, ref)}

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    owner_ref =
      Enum.find_value(state.leases, fn {key, lease} -> if lease.worker_ref == ref, do: key end)

    {:noreply, release(state, owner_ref || ref)}
  end

  defp release(state, ref) do
    case Map.pop(state.leases, ref) do
      {nil, _} ->
        state

      {lease, leases} ->
        Process.demonitor(ref, [:flush])
        if lease.worker_ref, do: Process.demonitor(lease.worker_ref, [:flush])
        if lease.worker, do: Process.exit(lease.worker, :kill)
        %{state | leases: leases}
    end
  end

  defp safe(callback) do
    callback.()
  rescue
    _ -> {:error, :upstream_unavailable}
  catch
    _, _ -> {:error, :upstream_unavailable}
  end
end
