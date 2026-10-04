defmodule AiControl.Workflows.Runtime do
  @moduledoc "Deadline and monitored local workers. Persistence authorizes every dispatch."
  use GenServer

  alias AiControl.{Repo, Workflows}
  alias AiControl.Workflows.{Manager, Run}

  def start_link(run),
    do: GenServer.start_link(__MODULE__, run, name: via(run.organization_id, run.id))

  def child_spec(run),
    do: %{id: {__MODULE__, run.id}, start: {__MODULE__, :start_link, [run]}, restart: :temporary}

  def via(org, id), do: {:via, Registry, {AiControl.Workflows.Registry, {org, id}}}
  def present?(org, id), do: Registry.lookup(AiControl.Workflows.Registry, {org, id}) != []

  def ensure(run) do
    case DynamicSupervisor.start_child(AiControl.Workflows.DynamicSupervisor, {__MODULE__, run}) do
      {:ok, pid} -> Manager.watch(run, pid)
      {:error, {:already_started, _}} -> :ok
      _ -> {:error, :workflow_unavailable}
    end
  end

  def track(ctx, worker, owner \\ self()),
    do: GenServer.call(via(ctx.organization_id, ctx.run_id), {:track, ctx, worker, owner})

  def untrack(ctx, worker),
    do: GenServer.cast(via(ctx.organization_id, ctx.run_id), {:untrack, worker})

  @impl true
  def init(run) do
    Phoenix.PubSub.subscribe(AiControl.PubSub, "organizations:#{run.organization_id}:workflows")
    {:ok, %{run: run, workers: %{}, timer: timer(run)}}
  end

  @impl true
  def handle_call({:track, ctx, worker, owner}, _, state) do
    if state.run.status == "running" do
      ref = Process.monitor(worker)
      owner_ref = Process.monitor(owner)
      {:reply, :ok, put_in(state.workers[worker], {ctx, ref, owner_ref})}
    else
      {:reply, {:error, :workflow_terminal}, state}
    end
  end

  @impl true
  def handle_cast({:untrack, worker}, state), do: {:noreply, remove(state, worker)}
  @impl true
  def handle_info(:deadline, state) do
    Workflows.expire(state.run.organization_id, state.run.id)
    refresh(state)
  end

  def handle_info(:workflows_changed, state), do: refresh(state)

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    worker =
      Enum.find_value(state.workers, fn {pid, {_, worker_ref, owner_ref}} ->
        if ref in [worker_ref, owner_ref], do: pid
      end)

    if worker do
      {ctx, _, _} = state.workers[worker]
      Process.exit(worker, :kill)
      Workflows.cleanup(ctx)
      Workflows.finish(ctx)
    end

    {:noreply, remove(state, worker)}
  end

  defp refresh(state) do
    Process.cancel_timer(state.timer)

    case Repo.get(Run, state.run.id, log: false) do
      %Run{status: "running"} = run ->
        {:noreply, %{state | run: run, timer: timer(run)}}

      %Run{status: "limit_exceeded"} ->
        {:stop, :normal, state}

      _ ->
        for {worker, _} <- state.workers, do: Process.exit(worker, :kill)
        {:stop, :normal, state}
    end
  rescue
    _ -> {:stop, :workflow_unavailable, state}
  end

  defp timer(run),
    do:
      Process.send_after(
        self(),
        :deadline,
        max(1, DateTime.diff(run.deadline, Workflows.now(), :millisecond))
      )

  defp remove(state, worker) do
    case Map.pop(state.workers, worker) do
      {nil, _} ->
        state

      {{_, ref, owner_ref}, workers} ->
        Process.demonitor(ref, [:flush])
        Process.demonitor(owner_ref, [:flush])
        %{state | workers: workers}
    end
  end
end
