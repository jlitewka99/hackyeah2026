defmodule AiControl.Workflows do
  @moduledoc "Durable, tenant-bound root limits. Transactions lock organization before run and receipts."
  import Ecto.Query

  alias AiControl.Accounts.Scope
  alias AiControl.Agents.Agent
  alias AiControl.ApiKeys.Principal
  alias AiControl.{Audit, Budgets, Policies, Repo}
  alias AiControl.Budgets.Reservation
  alias AiControl.Organizations.{Access, Grants, Organization}
  alias AiControl.Security.Fingerprint
  alias AiControl.Tools.{Execution, Executions}
  alias AiControl.Workflows.{Action, Context, Operation, Participant, Run, Runtime}

  @statuses ~w(running completed stopped limit_exceeded interrupted)
  def statuses, do: @statuses

  def now,
    do:
      Keyword.get(Application.get_env(:ai_control, __MODULE__, []), :clock, &DateTime.utc_now/0).()

  def create(%Principal{} = identity, params, key) do
    with {:ok, key} <- Ecto.UUID.cast(key),
         true <- is_map(params) && Map.keys(params) == ["goal"],
         goal when is_binary(goal) <- params["goal"],
         goal = String.trim(goal),
         true <- String.valid?(goal) && length(String.codepoints(goal)) in 1..240,
         {:ok, policy, current} <- Policies.snapshot_for_models(identity, nil),
         true <- policy.settings["schema_version"] in [5, 6],
         {:ok, fingerprint} <- fingerprint(current.organization_id, {"goal", goal}) do
      result =
        transaction(current.organization_id, fn ->
          create!(current, policy, key, goal, fingerprint)
        end)

      start_runtime(result)
    else
      :error -> {:error, :invalid_request}
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def create(_, _, _), do: {:error, :forbidden}

  defp create!(identity, policy, key, goal, fingerprint) do
    existing =
      Repo.get_by(
        Run,
        [
          organization_id: identity.organization_id,
          owner_agent_id: identity.agent_id,
          idempotency_key: key
        ],
        log: false
      )

    if existing do
      if existing.goal_digest != fingerprint.digest ||
           existing.fingerprint_key_id != fingerprint.key_id,
         do: Repo.rollback(:workflow_conflict)

      {:ok, {existing, root_participant(existing), :existing}}
    else
      limits = policy.settings["budgets"]["workflow"]
      # A bounded local registry must not be exhausted by many tiny runs.
      active =
        Repo.aggregate(
          from(r in Run,
            where: r.organization_id == ^identity.organization_id and r.status == "running"
          ),
          :count
        )

      if active >= 100, do: Repo.rollback(:capacity_exceeded)

      run =
        Repo.insert!(
          %Run{
            organization_id: identity.organization_id,
            owner_agent_id: identity.agent_id,
            api_key_id: identity.api_key_id,
            idempotency_key: key,
            goal: goal,
            goal_digest: fingerprint.digest,
            fingerprint_key_id: fingerprint.key_id,
            policy_version: policy.version,
            limits: limits,
            started_at: now(),
            deadline: DateTime.add(now(), limits["max_duration_seconds"], :second)
          },
          log: false
        )

      participant =
        Repo.insert!(
          %Participant{
            organization_id: run.organization_id,
            run_id: run.id,
            agent_id: identity.agent_id,
            depth: 0,
            inserted_at: now()
          },
          log: false
        )

      audit!(identity, run, participant, "created", nil)
      {:ok, {run, participant, :new}}
    end
  end

  defp start_runtime({:ok, {run, participant, :new}}) do
    case Runtime.ensure(run) do
      :ok ->
        {:ok, {run, participant}}

      _ ->
        interrupt(run.organization_id, run.id)
        {:error, :workflow_unavailable}
    end
  end

  defp start_runtime({:ok, {run, participant, :existing}}) do
    if run.status != "running" || Runtime.present?(run.organization_id, run.id) do
      {:ok, {run, participant}}
    else
      interrupt(run.organization_id, run.id)
      {:error, :workflow_terminal}
    end
  end

  defp start_runtime(error), do: error

  def resolve(_identity, policy, nil) do
    if policy.settings["schema_version"] in [5, 6],
      do: {:error, :workflow_context_required},
      else: {:ok, nil}
  end

  def resolve(%Principal{} = identity, policy, reference) do
    with {:ok, run_id, participant_id} <- reference_ids(reference),
         {:ok, current} <- Policies.refresh_identity(identity) do
      transaction(current.organization_id, fn ->
        resolve_locked(current, policy, run_id, participant_id)
      end)
    end
  end

  def resolve(_, _, _), do: {:error, :forbidden}

  defp resolve_locked(current, policy, run_id, participant_id) do
    run = locked!(current.organization_id, run_id)
    participant = member!(run, participant_id, current.agent_id)

    with {:ok, run} <- active!(run, policy),
         :ok <- ancestors_active(run, participant),
         :ok <- runtime_present(run) do
      resolve_depth(run, participant, current)
    end
  end

  defp resolve_depth(run, participant, current) do
    if participant.depth > run.limits["max_delegation_depth"],
      do: exceed!(run, "max_delegation_depth"),
      else: {:ok, %{context(run, participant) | api_key_id: current.api_key_id}}
  end

  defp reference_ids(%{run_id: run, participant_id: participant}) do
    with {:ok, run} <- Ecto.UUID.cast(run),
         {:ok, participant} <- Ecto.UUID.cast(participant),
         do: {:ok, run, participant},
         else: (_ -> {:error, :invalid_request})
  end

  defp reference_ids(_), do: {:error, :invalid_request}

  def admit(ctx, policy, kind, payload, request_id \\ Ecto.UUID.generate())
  def admit(nil, _, _, _, _), do: {:ok, nil}

  def admit(%Context{} = ctx, policy, kind, payload, request_id) do
    with {:ok, fingerprint} <-
           fingerprint(
             ctx.organization_id,
             {kind, Action.canonical(kind, payload)}
           ) do
      transaction(ctx.organization_id, fn ->
        admit_locked(ctx, policy, kind, fingerprint, request_id)
      end)
    end
  end

  defp admit_locked(ctx, policy, kind, fingerprint, request_id) do
    run = locked!(ctx.organization_id, ctx.run_id)
    _ = member!(run, ctx.participant_id, ctx.agent_id)

    with {:ok, run} <- active!(run, policy) do
      existing =
        Repo.get_by(Operation, [organization_id: ctx.organization_id, request_id: request_id],
          log: false
        )

      admit_operation(existing, run, ctx, kind, fingerprint, request_id)
    end
  end

  defp admit_operation(%Operation{} = existing, _run, ctx, kind, fingerprint, _request_id) do
    if existing.run_id != ctx.run_id || existing.participant_id != ctx.participant_id ||
         existing.fingerprint_digest != fingerprint.digest || existing.kind != kind,
       do: Repo.rollback(:workflow_conflict)

    if existing.status == "awaiting_review", do: update!(existing, status: "admitted")
    {:ok, %{ctx | operation_id: existing.id}}
  end

  defp admit_operation(nil, run, ctx, kind, fingerprint, request_id) do
    repeats =
      Repo.aggregate(
        from(o in Operation,
          where:
            o.run_id == ^run.id and o.fingerprint_digest == ^fingerprint.digest and
              o.fingerprint_key_id == ^fingerprint.key_id
        ),
        :count
      )

    cond do
      run.calls + 1 > run.limits["max_calls"] -> exceed!(run, "max_calls")
      repeats + 1 > run.limits["max_repeated_actions"] -> exceed!(run, "max_repeated_actions")
      true -> record_operation(run, ctx, kind, fingerprint, request_id)
    end
  end

  defp record_operation(run, ctx, kind, fingerprint, request_id) do
    operation =
      Repo.insert!(
        %Operation{
          organization_id: ctx.organization_id,
          run_id: ctx.run_id,
          participant_id: ctx.participant_id,
          request_id: request_id,
          kind: kind,
          fingerprint_digest: fingerprint.digest,
          fingerprint_key_id: fingerprint.key_id,
          inserted_at: now()
        },
        log: false
      )

    update!(run, calls: run.calls + 1)
    {:ok, %{ctx | operation_id: operation.id}}
  end

  def delegate(identity, run_id, parent_id, params, key, opts \\ [])

  def delegate(%Principal{} = identity, run_id, parent_id, params, key, opts) do
    with {:ok, key} <- Ecto.UUID.cast(key),
         true <- is_map(params) && Map.keys(params) == ["target_agent_id"],
         {:ok, target} <- Ecto.UUID.cast(params["target_agent_id"]),
         {:ok, policy, current} <- Policies.snapshot_for_models(identity, nil),
         {:ok, ctx} <- resolve(current, policy, %{run_id: run_id, participant_id: parent_id}),
         request_id = opts[:request_id] || Ecto.UUID.generate(),
         {:ok, ticket} <-
           AiControl.Approvals.prepare(
             current,
             "delegation",
             params,
             policy,
             request_id,
             opts |> Keyword.put(:run_context, ctx) |> Keyword.put(:idempotency_key, key)
           ) do
      try do
        transaction(current.organization_id, fn ->
          delegate_locked(current, policy, ctx, target, key, ticket)
        end)
      after
        AiControl.Approvals.finish(ticket)
      end
    else
      :error -> {:error, :invalid_request}
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def delegate(_, _, _, _, _, _), do: {:error, :forbidden}

  defp delegate_locked(current, policy, ctx, target, key, ticket) do
    run = locked!(current.organization_id, ctx.run_id)
    parent = member!(run, ctx.participant_id, current.agent_id)

    existing =
      Repo.get_by(Participant, [run_id: run.id, parent_id: parent.id, idempotency_key: key],
        log: false
      )

    delegate_participant(existing, current, policy, ctx, run, parent, {target, key, ticket})
  end

  defp delegate_participant(%Participant{} = existing, _, _, _, _, _, {target, _, _}) do
    if existing.agent_id != target, do: Repo.rollback(:workflow_conflict)
    {:ok, existing}
  end

  defp delegate_participant(nil, current, policy, ctx, run, parent, {target, key, ticket}) do
    with {:ok, run} <- active!(run, policy),
         :ok <- delegation_access(run, parent, target, policy),
         {:ok, admitted} <-
           admit(
             ctx,
             policy,
             "delegation",
             %{"target_agent_id" => target},
             if(ticket, do: ticket.operation_request_id, else: Ecto.UUID.generate())
           ),
         :ok <-
           AiControl.Approvals.gate(ticket, current, %{"target_agent_id" => target}, policy, []),
         :ok <- AiControl.Approvals.consume!(ticket, current, policy) do
      participant =
        Repo.insert!(
          %Participant{
            organization_id: run.organization_id,
            run_id: run.id,
            agent_id: target,
            parent_id: parent.id,
            depth: parent.depth + 1,
            idempotency_key: key,
            inserted_at: now()
          },
          log: false
        )

      finish_operation!(admitted, "finished")
      audit!(current, run, participant, "delegated", nil)
      {:ok, participant}
    end
  end

  defp delegation_access(run, parent, target, policy) do
    if !active_agent?(run.organization_id, target) ||
         !(policy.settings["allowed_agents"] == ["*"] ||
             target in policy.settings["allowed_agents"]),
       do: Repo.rollback(:forbidden)

    if parent.depth + 1 > run.limits["max_delegation_depth"],
      do: exceed!(run, "max_delegation_depth"),
      else: :ok
  end

  def transition(identity, id, action) when action in ["stop", "complete"] do
    with {:ok, run} <- fetch(identity, id, "workflows.manage") do
      transaction(run.organization_id, fn -> authorized_transition(identity, run, action) end)
    end
  end

  defp authorized_transition(identity, run, action) do
    with {:ok, _} <- fetch(identity, run.id, "workflows.manage"),
         do: transition_locked(locked!(run.organization_id, run.id), identity, action)
  end

  defp transition_locked(%Run{status: "running"} = run, identity, action) do
    in_flight =
      Repo.exists?(
        from(o in Operation, where: o.run_id == ^run.id and o.status in ~w(admitted dispatching))
      )

    if action == "complete" && in_flight, do: Repo.rollback(:workflow_conflict)
    status = if action == "complete", do: "completed", else: "stopped"
    {:ok, terminal!(run, status, nil, identity)}
  end

  defp transition_locked(run, _, action) do
    if action == "complete" && run.status != "completed", do: Repo.rollback(:workflow_terminal)
    {:ok, run}
  end

  def fetch(identity, id, permission \\ "workflows.read") do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, current} <- read_identity(identity, permission),
         org = organization_id(current),
         %Run{} = run <- Repo.get_by(Run, [id: id, organization_id: org], log: false),
         true <- visible?(current, run, permission) do
      {:ok, run}
    else
      {:error, _} = error -> error
      _ -> {:error, :forbidden}
    end
  rescue
    _ -> {:error, :workflow_unavailable}
  end

  def page(identity, params \\ %{}) do
    with {:ok, current} <- read_identity(identity, "workflows.read"),
         org = organization_id(current),
         true <- Map.get(params, "status", "") in ["" | @statuses],
         {:ok, cursor} <- parse_cursor(params["cursor"]),
         {:ok, agent_id} <- optional_uuid(params["agent_id"]) do
      query =
        from(r in Run,
          where: r.organization_id == ^org,
          order_by: [desc: r.started_at, desc: r.id]
        )

      query = owner_query(query, current)

      query =
        if params["status"] in @statuses,
          do: from(r in query, where: r.status == ^params["status"]),
          else: query

      query = if agent_id, do: from(r in query, where: r.owner_agent_id == ^agent_id), else: query

      query =
        if cursor,
          do:
            from(r in query,
              where:
                r.started_at < ^elem(cursor, 0) or
                  (r.started_at == ^elem(cursor, 0) and r.id < ^elem(cursor, 1))
            ),
          else: query

      rows = Repo.all(limit(query, 51), log: false)
      items = Enum.take(rows, 50)
      {:ok, %{runs: items, next: if(length(rows) > 50, do: cursor(List.last(items)))}}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  rescue
    _ -> {:error, :workflow_unavailable}
  end

  defp owner_query(query, %Principal{} = current),
    do: from(r in query, where: r.owner_agent_id == ^current.agent_id)

  defp owner_query(query, %Scope{grants: %{agents: ["*"]}}), do: query

  defp owner_query(query, current),
    do: from(r in query, where: r.owner_agent_id in ^current.grants.agents)

  def participants(identity, run) do
    with {:ok, current} <- read_identity(identity, "workflows.read"),
         {:ok, _} <- fetch(current, run.id) do
      query =
        from(p in Participant,
          join: a in Agent,
          on: a.id == p.agent_id and a.organization_id == p.organization_id,
          where: p.run_id == ^run.id and p.organization_id == ^run.organization_id,
          order_by: [asc: p.inserted_at, asc: p.id],
          select: %{p | name: a.name}
        )

      query = participant_query(query, current, run)

      rows = Repo.all(query, log: false)
      visible_ids = MapSet.new(rows, & &1.id)

      {:ok,
       Enum.map(rows, fn p ->
         %{
           p
           | parent_visible?: MapSet.member?(visible_ids, p.parent_id),
             parent_id: if(MapSet.member?(visible_ids, p.parent_id), do: p.parent_id)
         }
       end)}
    end
  rescue
    _ -> {:error, :workflow_unavailable}
  end

  defp participant_query(query, %Scope{grants: %{agents: ["*"]}}, _), do: query

  defp participant_query(query, %Scope{} = current, _),
    do: from([p, a] in query, where: a.id in ^current.grants.agents)

  defp participant_query(query, %Principal{agent_id: agent}, %{owner_agent_id: agent}), do: query

  defp participant_query(query, current, _),
    do: from(p in query, where: p.agent_id == ^current.agent_id)

  def audit_reference(%Principal{} = identity, request_id) do
    case Repo.one(
           from(o in Operation,
             join: p in Participant,
             on: p.id == o.participant_id,
             where:
               o.organization_id == ^identity.organization_id and o.request_id == ^request_id and
                 p.agent_id == ^identity.agent_id,
             select: %{run_id: o.run_id, participant_id: p.id}
           ),
           log: false
         ) do
      nil ->
        tool_audit_reference(identity, request_id)

      reference ->
        reference
    end
  end

  def audit_reference(_, _), do: %{}

  defp tool_audit_reference(identity, request_id) do
    query =
      from(e in Execution,
        where:
          e.organization_id == ^identity.organization_id and e.request_id == ^request_id and
            e.agent_id == ^identity.agent_id and not is_nil(e.run_id),
        limit: 1
      )

    case Repo.one(query, log: false) do
      %{run_id: run, participant_id: participant} -> %{run_id: run, participant_id: participant}
      _ -> %{}
    end
  end

  def evidence(run, participant \\ nil) do
    workflow =
      Repo.get_by(
        AiControl.Budgets.Workflow,
        [organization_id: run.organization_id, workflow_id: run.id],
        log: false
      )

    %{
      run_id: run.id,
      participant_id: if(participant, do: participant.id),
      status: run.status,
      reason: run.reason,
      started_at: run.started_at,
      deadline: run.deadline,
      finished_at: run.finished_at,
      limits: run.limits,
      calls: run.calls,
      tokens: run.tokens,
      reserved_tokens: run.reserved_tokens,
      tool_calls: if(workflow, do: workflow.calls, else: 0)
    }
  end

  # Called within the budget/execution transaction, after the organization lock.
  def reserve!(nil, _), do: :ok

  def reserve!(ctx, amount) do
    run = locked!(ctx.organization_id, ctx.run_id)

    with {:ok, run} <- active!(run) do
      if run.tokens + run.reserved_tokens + amount > run.limits["max_tokens"] do
        exceed!(run, "max_tokens")
      else
        update!(run, reserved_tokens: run.reserved_tokens + amount)
        :ok
      end
    end
  end

  def settle!(nil, _, _), do: :ok

  def settle!(ctx, reserved, tokens) do
    run = locked!(ctx.organization_id, ctx.run_id)

    run =
      update!(run, reserved_tokens: run.reserved_tokens - reserved, tokens: run.tokens + tokens)

    if run.status == "running" && run.tokens > run.limits["max_tokens"],
      do: exceed!(run, "max_tokens"),
      else: :ok
  end

  def release!(nil, _), do: :ok

  def release!(ctx, amount) do
    run = locked!(ctx.organization_id, ctx.run_id)
    update!(run, reserved_tokens: run.reserved_tokens - amount)
    :ok
  end

  def dispatch!(nil), do: :ok

  def dispatch!(ctx) do
    run = locked!(ctx.organization_id, ctx.run_id)
    participant = member!(run, ctx.participant_id, ctx.agent_id)

    with {:ok, policy, _} <- dispatch_identity(ctx),
         {:ok, run} <- active!(run, policy),
         :ok <- dispatch_limits(run, participant, ctx),
         :ok <- ancestors_active(run, participant),
         :ok <- runtime_present(run) do
      if ctx.operation_id, do: finish_operation!(ctx, "dispatching")
      :ok
    end
  end

  defp dispatch_limits(run, participant, ctx) do
    operation = if ctx.operation_id, do: Repo.get(Operation, ctx.operation_id, log: false)

    cond do
      participant.depth > run.limits["max_delegation_depth"] ->
        exceed!(run, "max_delegation_depth")

      operation && operation.kind == "tool" &&
          evidence(run).tool_calls + 1 > run.limits["tool_calls"] ->
        exceed!(run, "tool_calls")

      true ->
        :ok
    end
  end

  def finish(nil), do: :ok

  def finish(ctx) do
    transaction(ctx.organization_id, fn ->
      status = if uncertain?(ctx), do: "uncertain", else: "finished"
      operation = Repo.get(Operation, ctx.operation_id, log: false)
      if operation && operation.status != "awaiting_review", do: finish_operation!(ctx, status)
      {:ok, :ok}
    end)
  end

  defp uncertain?(ctx) do
    case Repo.get(Operation, ctx.operation_id, log: false) do
      nil ->
        false

      operation ->
        Repo.exists?(
          from(r in Reservation,
            where:
              r.organization_id == ^ctx.organization_id and r.request_id == ^operation.request_id and
                r.status == "uncertain"
          )
        ) ||
          Repo.exists?(
            from(e in Execution,
              where:
                e.organization_id == ^ctx.organization_id and
                  e.request_id == ^operation.request_id and e.status == "uncertain"
            )
          )
    end
  end

  defp dispatch_identity(ctx) do
    Policies.snapshot_for_models(
      %Principal{
        organization_id: ctx.organization_id,
        agent_id: ctx.agent_id,
        api_key_id: ctx.api_key_id
      },
      nil
    )
  end

  defp finish_operation!(ctx, status) do
    if ctx.operation_id do
      Repo.update_all(
        from(o in Operation,
          where:
            o.id == ^ctx.operation_id and o.run_id == ^ctx.run_id and
              o.participant_id == ^ctx.participant_id
        ),
        [set: [status: status]],
        log: false
      )
    end
  end

  def run(nil, callback), do: callback.()

  def run(ctx, callback) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(AiControl.Workflows.Tasks, fn ->
        receive do
          :run -> callback.()
        end
      end)

    try do
      with :ok <- Runtime.track(ctx, task.pid, owner), :ok <- check(ctx) do
        send(task.pid, :run)
        timeout = remaining(ctx)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} ->
            case check(ctx) do
              :ok -> result
              {:error, :workflow_terminal} -> terminal_result(ctx)
              error -> error
            end

          _ ->
            expire(ctx.organization_id, ctx.run_id)
            terminal_result(ctx)
        end
      end
    catch
      :exit, _ -> {:error, :workflow_unavailable}
    after
      Task.shutdown(task, :brutal_kill)
      cleanup(ctx)
      if Runtime.present?(ctx.organization_id, ctx.run_id), do: Runtime.untrack(ctx, task.pid)
      finish(ctx)
    end
  end

  @doc false
  def terminal_result(ctx) do
    case Repo.get(Run, ctx.run_id, log: false) do
      %Run{status: "limit_exceeded"} -> {:error, :workflow_limit_exceeded}
      _ -> {:error, :workflow_terminal}
    end
  end

  def remaining(ctx) do
    case Repo.get_by(Run, [organization_id: ctx.organization_id, id: ctx.run_id], log: false) do
      %Run{} = run -> max(1, DateTime.diff(run.deadline, now(), :millisecond))
      _ -> 1
    end
  end

  def cleanup(ctx) do
    operation = Repo.get(Operation, ctx.operation_id, log: false)

    if operation && operation.status != "awaiting_review" do
      receipt =
        Repo.get_by(
          Reservation,
          [
            organization_id: ctx.organization_id,
            run_id: ctx.run_id,
            request_id: operation.request_id
          ],
          log: false
        )

      if receipt, do: Budgets.abandon(receipt)
      Executions.recover_request(ctx.organization_id, operation.request_id)
    end

    :ok
  end

  def attach(nil), do: :ok
  def attach(ctx), do: Runtime.track(ctx, self())
  def detach(nil), do: :ok

  def detach(ctx) do
    if Runtime.present?(ctx.organization_id, ctx.run_id), do: Runtime.untrack(ctx, self())
    :ok
  end

  def check(nil), do: :ok

  def check(ctx) do
    transaction(ctx.organization_id, fn ->
      case active!(locked!(ctx.organization_id, ctx.run_id)) do
        {:ok, _} -> :ok
        error -> error
      end
    end)
  end

  def expire(org, id) do
    transaction(org, fn ->
      run = locked!(org, id)

      case active!(run) do
        {:ok, _} -> {:ok, run}
        error -> error
      end
    end)
  end

  def interrupt(org, id), do: terminate_run(org, id, "interrupted", "process_interrupted")

  defp terminate_run(org, id, status, reason) do
    transaction(org, fn ->
      run = locked!(org, id)
      if run.status == "running", do: {:ok, terminal!(run, status, reason)}, else: {:ok, run}
    end)
  end

  def recover do
    case Repo.query("SELECT to_regclass('workflow_runs')", [], log: false) do
      {:ok, %{rows: [[nil]]}} ->
        :ok

      {:ok, _} ->
        for run <- Repo.all(from(r in Run, where: r.status == "running"), log: false) do
          recover_run(run)
        end

        :ok

      _ ->
        raise "workflow recovery unavailable"
    end
  end

  defp recover_run(run) do
    case interrupt(run.organization_id, run.id) do
      {:ok, _} -> reconcile_operations(run.organization_id, run.id)
      _ -> raise "workflow recovery unavailable"
    end
  end

  def reconcile_operations(org, id) do
    transaction(org, fn ->
      _ = locked!(org, id)

      Repo.update_all(
        from(o in Operation, where: o.run_id == ^id and o.status in ~w(admitted dispatching)),
        [set: [status: "uncertain"]],
        log: false
      )

      {:ok, :ok}
    end)
  end

  defp active!(run, policy \\ nil) do
    run = tighten!(run, policy)

    cond do
      run.status != "running" -> {:error, :workflow_terminal}
      DateTime.compare(now(), run.deadline) != :lt -> exceed!(run, "max_duration_seconds")
      run.calls > run.limits["max_calls"] -> exceed!(run, "max_calls")
      run.tokens + run.reserved_tokens > run.limits["max_tokens"] -> exceed!(run, "max_tokens")
      true -> {:ok, run}
    end
  end

  defp tighten!(run, %{settings: %{"schema_version" => version}} = policy)
       when version in [5, 6] do
    limits =
      Map.new(run.limits, fn {key, value} ->
        {key, min(value, policy.settings["budgets"]["workflow"][key])}
      end)

    if limits == run.limits,
      do: run,
      else:
        update!(run,
          limits: limits,
          deadline: DateTime.add(run.started_at, limits["max_duration_seconds"], :second)
        )
  end

  defp tighten!(run, _), do: run

  defp exceed!(run, reason) do
    terminal!(run, "limit_exceeded", reason)
    {:error, :workflow_limit_exceeded}
  end

  def exceed(ctx, reason),
    do: terminate_run(ctx.organization_id, ctx.run_id, "limit_exceeded", reason)

  defp terminal!(run, status, reason, identity \\ nil) do
    identity =
      identity ||
        %Principal{
          organization_id: run.organization_id,
          agent_id: run.owner_agent_id,
          api_key_id: run.api_key_id
        }

    updated = update!(run, status: status, reason: reason, finished_at: now())
    audit!(identity, updated, nil, status, reason)
    :ok = AiControl.Approvals.invalidate_run!(run.organization_id, run.id)
    updated
  end

  defp audit!(identity, run, participant, event, reason) do
    case Audit.record_workflow(
           identity,
           run.id,
           if(participant, do: participant.id),
           event,
           reason
         ) do
      {:ok, _} -> :ok
      _ -> Repo.rollback(:audit_unavailable)
    end
  end

  defp root_participant(run),
    do:
      Repo.one!(from(p in Participant, where: p.run_id == ^run.id and is_nil(p.parent_id)),
        log: false
      )

  defp context(run, participant),
    do: %Context{
      organization_id: run.organization_id,
      run_id: run.id,
      participant_id: participant.id,
      agent_id: participant.agent_id
    }

  defp locked!(org, id) do
    case Repo.one(
           from(r in Run, where: r.organization_id == ^org and r.id == ^id, lock: "FOR UPDATE"),
           log: false
         ) do
      nil -> Repo.rollback(:forbidden)
      run -> run
    end
  end

  defp member!(run, id, agent) do
    case Repo.get_by(
           Participant,
           [id: id, run_id: run.id, organization_id: run.organization_id, agent_id: agent],
           log: false
         ) do
      nil -> Repo.rollback(:forbidden)
      participant -> participant
    end
  end

  defp ancestors_active(run, participant) do
    if active_agent?(run.organization_id, run.owner_agent_id) &&
         active_agent?(run.organization_id, participant.agent_id) do
      if participant.parent_id do
        parent =
          Repo.get_by!(
            Participant,
            [id: participant.parent_id, run_id: run.id, organization_id: run.organization_id],
            log: false
          )

        ancestors_active(run, parent)
      else
        :ok
      end
    else
      {:error, :forbidden}
    end
  end

  defp active_agent?(org, agent),
    do:
      Repo.exists?(
        from(a in Agent,
          where: a.organization_id == ^org and a.id == ^agent and a.status == :active
        )
      )

  defp runtime_present(run),
    do:
      if(Runtime.present?(run.organization_id, run.id),
        do: :ok,
        else: {:error, :workflow_unavailable}
      )

  defp organization_id(%Principal{} = p), do: p.organization_id
  defp organization_id(%Scope{} = s), do: s.organization.id

  defp read_identity(%Principal{} = identity, _) do
    Policies.refresh_identity(identity)
  end

  defp read_identity(%Scope{} = identity, permission) do
    Access.authorize(identity, permission)
  end

  defp read_identity(_, _), do: {:error, :forbidden}

  defp visible?(%Principal{} = identity, run, "workflows.manage"),
    do: identity.agent_id == run.owner_agent_id

  defp visible?(%Principal{} = identity, run, _) do
    Repo.exists?(
      from(p in Participant,
        where:
          p.run_id == ^run.id and p.organization_id == ^identity.organization_id and
            p.agent_id == ^identity.agent_id
      )
    )
  end

  defp visible?(%Scope{} = identity, run, permission) do
    case Access.authorize(identity, permission) do
      {:ok, current} -> Grants.includes?(current.grants.agents, run.owner_agent_id)
      _ -> false
    end
  end

  defp fingerprint(org, value),
    do: Fingerprint.content(org, :input, :erlang.term_to_binary({"workflow.action.v1", value}))

  defp update!(record, attrs),
    do: record |> Ecto.Changeset.change(attrs) |> Repo.update!(log: false)

  defp transaction(org, fun) do
    result =
      Repo.transaction(
        fn ->
          _ =
            Repo.one!(from(o in Organization, where: o.id == ^org, lock: "FOR UPDATE"),
              log: false
            )

          fun.()
        end,
        log: false
      )

    case result do
      {:ok, outcome} ->
        # Only wake readers/processes after the outermost transaction has committed.
        if !Repo.in_transaction?() do
          AiControl.Approvals.notify(org)

          Phoenix.PubSub.broadcast(
            AiControl.PubSub,
            "organizations:#{org}:workflows",
            :workflows_changed
          )
        end

        outcome

      error ->
        error
    end
  rescue
    _ -> {:error, :workflow_unavailable}
  catch
    :exit, _ -> {:error, :workflow_unavailable}
  end

  defp optional_uuid(value) when value in [nil, ""], do: {:ok, nil}

  defp optional_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :invalid_request}
    end
  end

  defp cursor(run),
    do:
      Base.url_encode64(Jason.encode!([DateTime.to_iso8601(run.started_at), run.id]),
        padding: false
      )

  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor(value) when is_binary(value) and byte_size(value) <= 256 do
    with {:ok, data} <- Base.url_decode64(value, padding: false),
         {:ok, [time, id]} <- Jason.decode(data),
         {:ok, time, 0} <- DateTime.from_iso8601(time),
         {:ok, id} <- Ecto.UUID.cast(id),
         do: {:ok, {time, id}},
         else: (_ -> {:error, :invalid_request})
  end

  defp parse_cursor(_), do: {:error, :invalid_request}
end
