defmodule AiControl.Gateway.Stream do
  @moduledoc "Supervised SSE lifetime. The session owns accounting even when its caller or worker dies."
  use GenServer, restart: :temporary

  alias AiControl.{Audit, Budgets, Gateway, Workflows}
  alias AiControl.Gateway.{Config, Measurements, StreamEvidence}
  alias AiControl.Workflows.Runtime

  def start(identity, params, opts) do
    args = {self(), identity, params, Keyword.put_new(opts, :request_id, Ecto.UUID.generate())}

    with {:ok, pid} <-
           DynamicSupervisor.start_child(AiControl.Gateway.Streams, {__MODULE__, args}),
         :ok <- GenServer.call(pid, :prepare, :infinity),
         do: {:ok, pid}
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)
  def begin(pid), do: GenServer.cast(pid, :begin)
  def complete(pid, counts), do: GenServer.call(pid, {:complete, counts}, :infinity)
  def delivered(pid), do: GenServer.call(pid, :delivered)
  def cancel(pid), do: GenServer.call(pid, :cancel, :infinity)

  @impl true
  def init({owner, identity, params, opts}) do
    {:ok, measurements} = Agent.start_link(fn -> %{} end)

    state = %{
      owner: owner,
      owner_ref: Process.monitor(owner),
      identity: identity,
      policy: nil,
      workflow: nil,
      workflow_timer: nil,
      params: params,
      opts: Keyword.put(opts, :measurements, measurements),
      receipt: nil,
      prepared: nil,
      task: nil,
      from: nil,
      phase: :prepare,
      stage: :input,
      started: System.monotonic_time(),
      delivery_started: nil,
      timer: nil,
      evidence: StreamEvidence.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:prepare, from, state) do
    session = self()

    opts =
      Keyword.merge(state.opts,
        stream_context: fn identity, policy, workflow ->
          GenServer.call(session, {:context, identity, policy, workflow})
        end,
        stream_admit: fn identity, model, policy ->
          GenServer.call(session, {:admit, identity, model, policy}, :infinity)
        end
      )

    task = worker(fn -> Gateway.prepare_stream(state.identity, state.params, opts) end)
    timer = Process.send_after(self(), {:timeout, :prepare}, Config.get(:llm_timeout))
    {:noreply, %{state | task: task, from: from, timer: timer}}
  end

  def handle_call({:context, identity, policy, workflow}, _, state) do
    result = if workflow, do: Runtime.track_stream(workflow, self(), state.owner), else: :ok

    timer =
      if workflow,
        do: Process.send_after(self(), :workflow_deadline, Workflows.remaining(workflow))

    {:reply, result,
     %{state | identity: identity, policy: policy, workflow: workflow, workflow_timer: timer}}
  end

  def handle_call({:admit, identity, model, policy}, _, state) do
    result =
      Budgets.admit(
        identity,
        state.opts[:agent_id],
        model,
        policy,
        state.opts[:request_id],
        DateTime.utc_now(),
        state.workflow
      )

    state =
      case result do
        {:ok, receipt} -> %{state | receipt: receipt}
        _ -> state
      end

    {:reply, result, state}
  end

  def handle_call({:received, bytes}, _, state) do
    evidence =
      state.evidence
      |> Map.update!("received_bytes", &(&1 + bytes))
      |> Map.update!("received_chunks", &(&1 + 1))

    {:reply, :ok, %{state | evidence: evidence}}
  end

  def handle_call({:usage, usage}, _, %{phase: :generation} = state) do
    # The session survives caller/worker cancellation and finishes this checkpoint first.
    started = System.monotonic_time()
    result = Budgets.settle(state.receipt, usage)
    Measurements.record(state.opts[:measurements], "budget_settlement", elapsed(started))

    result =
      case result do
        {:ok, _} -> :ok
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:sent, bytes}, _, %{phase: :delivery} = state) do
    evidence =
      state.evidence
      |> Map.update!("sent_bytes", &(&1 + bytes))
      |> Map.update!("sent_chunks", &(&1 + 1))

    {:reply, :ok, %{state | evidence: evidence}}
  end

  def handle_call({:complete, counts}, _, %{phase: :delivery} = state) do
    state = %{state | evidence: Map.merge(state.evidence, counts)}
    result = audit(state, "completed", "completed")

    if result == :ok,
      do: {:reply, :ok, %{state | phase: :finishing}},
      else: {:stop, :normal, result, state}
  end

  def handle_call(:delivered, _, %{phase: :finishing} = state), do: {:stop, :normal, :ok, state}

  def handle_call(:cancel, _, state) do
    state = stop_worker(state)
    _ = cleanup(state)
    _ = audit(state, "stream_cancelled", "cancelled")
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_cast(:begin, %{phase: :prepared} = state) do
    session = self()
    task = worker(fn -> Gateway.generate_stream(state.prepared, session) end)
    {:noreply, %{state | task: task, phase: :generation, stage: :output}}
  end

  @impl true
  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}
    result(state, result)
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state) do
    state = stop_worker(state)
    _ = cleanup(state)
    _ = audit(state, "stream_cancelled", "cancelled")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref}} = state),
    do: failure(%{state | task: nil}, {:error, :upstream_unavailable})

  def handle_info({:timeout, :prepare}, %{phase: :prepare} = state),
    do: failure(stop_worker(state), {:error, :upstream_timeout})

  def handle_info({:timeout, :delivery}, %{phase: phase} = state)
      when phase in [:delivery, :finishing] do
    # This watchdog also interrupts a caller blocked inside the socket adapter.
    _ = audit(state, "stream_delivery_timeout", "failed")
    Process.exit(state.owner, :kill)
    {:stop, :normal, state}
  end

  def handle_info({:timeout, _}, state), do: {:noreply, state}

  def handle_info(:workflow_deadline, state) do
    Workflows.expire(state.workflow.organization_id, state.workflow.run_id)
    failure(stop_worker(state), Workflows.terminal_result(state.workflow))
  end

  def handle_info(:workflow_terminated, state),
    do: failure(stop_worker(state), Workflows.terminal_result(state.workflow))

  @impl true
  def terminate(reason, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.workflow_timer, do: Process.cancel_timer(state.workflow_timer)
    state = stop_worker(state)
    _ = cleanup(state)
    finish_workflow(state.workflow)
    if reason != :normal, do: audit(state, "stream_cancelled", "cancelled")
    Agent.stop(state.opts[:measurements])
  end

  @impl true
  def format_status(status),
    do: Map.put(status, :state, Map.take(status.state, [:phase, :stage, :evidence]))

  defp result(%{phase: :prepare} = state, {:ok, prepared}) do
    Process.cancel_timer(state.timer)
    GenServer.reply(state.from, :ok)

    {:noreply,
     %{
       state
       | prepared: prepared,
         receipt: prepared.receipt,
         phase: :prepared,
         from: nil,
         timer: nil
     }}
  end

  defp result(%{phase: :generation} = state, {:ok, response}) do
    case audit(state, "stream_ready", "ready") do
      :ok ->
        send(state.owner, {self(), {:ready, response}})

        timer =
          Process.send_after(
            self(),
            {:timeout, :delivery},
            Config.get(:stream_delivery_timeout_ms)
          )

        {:noreply,
         %{state | phase: :delivery, timer: timer, delivery_started: System.monotonic_time()}}

      error ->
        failure(state, error)
    end
  end

  defp result(state, error), do: failure(state, error)

  defp failure(state, error) do
    cleanup_result = cleanup(state)
    error = if match?({:error, _}, cleanup_result), do: {:error, :budget_unavailable}, else: error

    code =
      case error do
        {:error, {code, _}} -> Atom.to_string(code)
        {:error, code} when is_atom(code) -> Atom.to_string(code)
        _ -> "upstream_unavailable"
      end

    result = if audit(state, code, "failed") == :ok, do: error, else: {:error, :audit_unavailable}

    if state.from,
      do: GenServer.reply(state.from, result),
      else: send(state.owner, {self(), result})

    {:stop, :normal, state}
  end

  defp audit(state, code, delivery) do
    duration = elapsed(state.started)
    timings = Measurements.snapshot(state.opts[:measurements]) |> Map.put("request", duration)

    timings =
      if state.delivery_started,
        do: Map.put(timings, "stream_delivery", elapsed(state.delivery_started)),
        else: timings

    evidence = Map.put(state.evidence, "delivery", delivery)
    budget = if state.receipt, do: Budgets.evidence(state.receipt)

    observation = %{
      operation: "chat",
      timings: timings,
      stream: evidence
    }

    :telemetry.execute([:ai_control, :gateway, :stream], %{duration_us: duration}, %{code: code})

    case Audit.record_gateway(
           state.identity,
           state.opts[:request_id],
           code,
           duration,
           state.policy,
           state.stage,
           budget,
           observation
         ) do
      {:ok, _} -> :ok
      _ -> {:error, :audit_unavailable}
    end
  rescue
    _ -> {:error, :audit_unavailable}
  catch
    :exit, _ -> {:error, :audit_unavailable}
  end

  defp cleanup(%{receipt: nil}), do: :ok
  defp cleanup(state), do: Budgets.abandon(state.receipt)

  defp finish_workflow(nil), do: :ok

  defp finish_workflow(context) do
    Workflows.finish(context)

    if Runtime.present?(context.organization_id, context.run_id),
      do: Runtime.untrack(context, self())
  end

  defp worker(callback) do
    Task.Supervisor.async_nolink(AiControl.Gateway.Tasks, fn ->
      try do
        callback.()
      rescue
        _ -> {:error, :upstream_unavailable}
      catch
        _, _ -> {:error, :upstream_unavailable}
      end
    end)
  end

  defp stop_worker(%{task: nil} = state), do: state

  defp stop_worker(state) do
    Task.shutdown(state.task, :brutal_kill)
    %{state | task: nil}
  end

  defp elapsed(started),
    do: System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
end
