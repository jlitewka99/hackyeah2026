defmodule AiControl.Workflows.Manager do
  @moduledoc "Monitor temporary runtimes; losing a runtime never resumes a run."
  use GenServer

  alias AiControl.Workflows

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def watch(run, pid), do: GenServer.call(__MODULE__, {:watch, run, pid})
  @impl true
  def init(_) do
    :ok = Workflows.recover()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:watch, run, pid}, _, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, Map.put(state, ref, {run.organization_id, run.id})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Map.pop(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {{org, id}, state} ->
        Workflows.interrupt(org, id)
        Workflows.reconcile_operations(org, id)
        {:noreply, state}
    end
  end
end
