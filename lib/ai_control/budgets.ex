defmodule AiControl.Budgets do
  @moduledoc "Durable UTC accounting. Lock organization, organization bucket, agent bucket, then receipt."
  import Ecto.Query

  alias AiControl.Accounts.Scope
  alias AiControl.ApiKeys.Principal
  alias AiControl.{Audit, Policies, Repo}
  alias AiControl.Budgets.{Bucket, Cache, Pricing, Reservation, ToolExecution, Usage, Workflow}
  alias AiControl.Organizations.{Access, Grants, Organization, ResourceResolver}
  alias AiControl.Policy.Snapshot

  def window(now) do
    utc = DateTime.from_unix!(DateTime.to_unix(now))
    %{utc | minute: 0, second: 0}
  end

  def hard_limit?(policy), do: configured_tokens?(policy.settings["budgets"])

  def admit(identity, agent_id, model, policy, request_id, now \\ DateTime.utc_now()) do
    with {:ok, current} <- Policies.refresh_identity(identity),
         :ok <- Policies.model_access(current, policy, agent_id, model),
         :ok <- resource_access(current, agent_id, model) do
      {org, agent} = resources(current, agent_id)

      transaction(fn -> admit!(org, agent, model, policy, request_id, now, current) end)
    end
  end

  defp admit!(org, agent, model, policy, request_id, now, identity) do
    lock_org(org)
    buckets = buckets(org, agent, window(now))

    case Repo.get_by(Reservation, organization_id: org, request_id: request_id) do
      nil ->
        check!(buckets, policy.settings["budgets"], "requests_per_hour", 1, now)
        increment(buckets, requests: 1)

        Repo.insert!(
          %Reservation{
            organization_id: org,
            agent_id: agent,
            request_id: request_id,
            actor_type: if(match?(%Principal{}, identity), do: "agent", else: "user"),
            user_id: if(match?(%Scope{}, identity), do: identity.user.id),
            api_key_id: if(match?(%Principal{}, identity), do: identity.api_key_id),
            window: window(now),
            model: model,
            policy_version: policy.version,
            policy_checksum: policy.checksum,
            limits: policy.settings["budgets"],
            policy_settings: policy.settings,
            price: Pricing.snapshot(model)
          },
          log: false
        )

      existing ->
        if existing.agent_id != agent || existing.model != model,
          do: Repo.rollback(:budget_conflict)

        existing
    end
  end

  def reserve(%Reservation{} = receipt, input, output)
      when is_integer(input) and input >= 0 and is_integer(output) and output > 0 do
    mutate(receipt, fn current, buckets ->
      if current.status != "admitted", do: Repo.rollback(:budget_conflict)
      check!(buckets, current.limits, "tokens_per_hour", input + output, DateTime.utc_now())
      increment(buckets, reserved: input + output)

      update_record(current,
        status: "reserved",
        input_tokens: input,
        output_limit: output,
        reserved_tokens: input + output
      )
    end)
  end

  def dispatch(%Reservation{} = receipt) do
    mutate(receipt, fn current, buckets ->
      if current.status not in ~w(admitted reserved), do: Repo.rollback(:budget_conflict)

      if current.status == "admitted" && configured_tokens?(current.limits),
        do: Repo.rollback(:tokenizer_unavailable)

      unbounded = current.status == "admitted"
      if unbounded, do: increment(buckets, unbounded: 1)

      update_record(current,
        status: "dispatching",
        unbounded: unbounded,
        dispatched_at: DateTime.utc_now()
      )
    end)
  end

  def settle(%Reservation{} = receipt, usage) do
    with {:ok, usage} <- Usage.normalize(usage) do
      mutate(receipt, &settle!(&1, &2, usage))
    end
  end

  defp settle!(current, buckets, usage) do
    cond do
      current.status == "settled" && current.usage == usage ->
        current

      current.status not in ~w(dispatching uncertain) ->
        Repo.rollback(:budget_conflict)

      true ->
        increment(buckets,
          tokens: usage["total_tokens"],
          reserved: -current.reserved_tokens,
          unbounded: if(current.unbounded, do: -1, else: 0)
        )

        update_record(current,
          status: "settled",
          usage: usage,
          cost: Pricing.cost(current.price, usage),
          unbounded: false,
          overrun: current.reserved_tokens > 0 && usage["total_tokens"] > current.reserved_tokens
        )
    end
  end

  @doc "Cancellation cleanup retains every persisted dispatch charge."
  def abandon(%Reservation{} = receipt) do
    mutate(receipt, fn current, buckets ->
      cond do
        current.status in ~w(admitted reserved) -> release!(current, buckets)
        current.status == "dispatching" -> update_record(current, status: "uncertain")
        true -> current
      end
    end)
  end

  defp release!(current, buckets) do
    increment(buckets,
      reserved: -current.reserved_tokens,
      unbounded: if(current.unbounded, do: -1, else: 0)
    )

    update_record(current,
      status: "released",
      unbounded: false,
      cost: if(current.price, do: Decimal.new(0))
    )
  end

  def evidence(%Reservation{} = receipt) do
    current = Repo.get!(Reservation, receipt.id, log: false)

    %{
      reservation_id: current.id,
      window: DateTime.to_iso8601(current.window),
      status: current.status,
      reserved_tokens: current.reserved_tokens,
      usage: current.usage,
      overrun: current.overrun,
      cost: cost_evidence(current),
      currency: if(current.price, do: current.price["currency"])
    }
  end

  defp cost_evidence(%{price: nil}), do: "not configured"
  defp cost_evidence(%{cost: nil}), do: "unavailable"
  defp cost_evidence(%{cost: cost}), do: Decimal.to_string(cost, :normal)

  def state(scope, agent_id \\ nil, now \\ DateTime.utc_now()) do
    with {:ok, current} <- Access.authorize(scope, "budgets.read"),
         true <-
           is_nil(agent_id) ||
             (ResourceResolver.owned?(current.organization.id, :agent, agent_id) &&
                Grants.includes?(current.grants.agents, agent_id)) do
      level = if agent_id, do: "agent", else: "organization"
      subject = agent_id || current.organization.id

      {:ok,
       Cache.read({current.organization.id, level, subject, window(now)}, fn ->
         Repo.get_by(Bucket,
           organization_id: current.organization.id,
           level: level,
           subject_id: subject,
           window: window(now)
         )
       end)}
    else
      _ -> {:error, :forbidden}
    end
  end

  @doc "Explicit operator evidence only: :not_sent or verified usage. Never a TTL refund."
  def reconcile(scope, id, resolution) do
    with {:ok, current} <- Access.authorize(scope, "budgets.manage"),
         %Reservation{} = receipt <-
           Repo.get_by(Reservation, id: id, organization_id: current.organization.id),
         true <- Grants.includes?(current.grants.agents, receipt.agent_id) do
      mutate(receipt, &reconcile!(&1, &2, current, resolution))
    else
      _ -> {:error, :forbidden}
    end
  end

  defp reconcile!(stored, buckets, scope, resolution) do
    with {:ok, current} <- Access.authorize(scope, "budgets.manage"),
         true <- Grants.includes?(current.grants.agents, stored.agent_id) do
      if stored.status not in ~w(dispatching uncertain), do: Repo.rollback(:budget_conflict)
      updated = resolve!(stored, buckets, resolution)

      case Audit.record_budget_reconciliation(current, updated.id, updated.status) do
        {:ok, _} -> updated
        _ -> Repo.rollback(:audit_unavailable)
      end
    else
      _ -> Repo.rollback(:forbidden)
    end
  end

  defp resolve!(stored, buckets, :not_sent), do: release!(stored, buckets)

  defp resolve!(stored, buckets, usage) do
    case Usage.normalize(usage) do
      {:ok, normalized} -> settle!(stored, buckets, normalized)
      _ -> Repo.rollback(:invalid_usage)
    end
  end

  @doc "Run before endpoint startup. CAS cleanup prevents dispatching released receipts."
  def recover do
    Repo.all(from(r in Reservation, where: r.status in ["admitted", "reserved", "dispatching"]),
      log: false
    )
    |> Enum.each(&abandon/1)

    :ok
  end

  def consume_tool_call(identity, agent_id, policy, workflow_id, execution_id) do
    with {:ok, current} <- Policies.refresh_identity(identity),
         true <- Snapshot.valid?(policy),
         true <- tool_agent_allowed?(current, agent_id, policy),
         {:ok, workflow_id} <- Ecto.UUID.cast(workflow_id),
         {:ok, execution_id} <- Ecto.UUID.cast(execution_id) do
      {org, agent} = resources(current, agent_id)

      transaction(fn -> tool_call!(org, agent, policy, workflow_id, execution_id) end)
    else
      _ -> {:error, :forbidden}
    end
  end

  defp tool_agent_allowed?(identity, agent_id, policy) do
    {_org, agent} = resources(identity, agent_id)
    allowed = policy.settings["allowed_agents"]
    selected = allowed == ["*"] || agent in allowed

    case identity do
      %Principal{} ->
        selected && agent_id in [nil, identity.agent_id]

      %Scope{} ->
        selected && Grants.includes?(identity.grants.agents, agent) &&
          ResourceResolver.owned?(identity.organization.id, :agent, agent)
    end
  end

  defp tool_call!(org, agent, policy, workflow_id, execution_id) do
    lock_org(org)

    Repo.insert!(%Workflow{organization_id: org, agent_id: agent, workflow_id: workflow_id},
      on_conflict: :nothing,
      conflict_target: [:organization_id, :workflow_id],
      log: false
    )

    workflow =
      Repo.one!(
        from(w in Workflow,
          where: w.organization_id == ^org and w.workflow_id == ^workflow_id,
          lock: "FOR UPDATE"
        ),
        log: false
      )

    if workflow.agent_id != agent, do: Repo.rollback(:forbidden)

    case Repo.get_by(ToolExecution, workflow_id: workflow.id, execution_id: execution_id) do
      nil -> record_tool!(workflow, policy, execution_id)
      existing -> existing
    end
  end

  defp record_tool!(workflow, policy, execution_id) do
    limit = policy.settings["budgets"]["workflow"]["tool_calls"]
    if limit != nil && workflow.calls + 1 > limit, do: Repo.rollback(:tool_budget_exceeded)
    update_record(workflow, calls: workflow.calls + 1)
    Repo.insert!(%ToolExecution{workflow_id: workflow.id, execution_id: execution_id}, log: false)
  end

  defp mutate(receipt, callback) do
    transaction(fn ->
      lock_org(receipt.organization_id)
      buckets = buckets(receipt.organization_id, receipt.agent_id, receipt.window)

      stored =
        Repo.one!(
          from(r in Reservation,
            where: r.id == ^receipt.id and r.organization_id == ^receipt.organization_id,
            lock: "FOR UPDATE"
          ),
          log: false
        )

      callback.(stored, buckets)
    end)
  end

  defp transaction(callback) do
    result = Repo.transaction(callback, log: false)
    Cache.clear()
    result
  rescue
    _ -> {:error, :budget_unavailable}
  catch
    :exit, _ -> {:error, :budget_unavailable}
  end

  defp lock_org(org),
    do: Repo.one!(from(o in Organization, where: o.id == ^org, lock: "FOR UPDATE"), log: false)

  defp buckets(org, agent, window) do
    Enum.map([{"organization", org}, {"agent", agent}], fn {level, subject} ->
      Repo.insert!(
        %Bucket{organization_id: org, level: level, subject_id: subject, window: window},
        on_conflict: :nothing,
        conflict_target: [:organization_id, :level, :subject_id, :window],
        log: false
      )

      Repo.one!(
        from(b in Bucket,
          where:
            b.organization_id == ^org and b.level == ^level and b.subject_id == ^subject and
              b.window == ^window,
          lock: "FOR UPDATE"
        ),
        log: false
      )
    end)
  end

  defp configured_tokens?(limits),
    do: Enum.any?(~w(organization agent), &(limits[&1]["tokens_per_hour"] != nil))

  defp check!(buckets, limits, field, additional, now) do
    Enum.each(buckets, &check_bucket!(&1, limits[&1.level][field], field, additional, now))
  end

  defp check_bucket!(bucket, limit, field, additional, now) do
    used =
      if field == "requests_per_hour", do: bucket.requests, else: bucket.tokens + bucket.reserved

    if limit != nil &&
         (used + additional > limit || (field == "tokens_per_hour" && bucket.unbounded > 0)) do
      code =
        if field == "requests_per_hour",
          do: :request_budget_exceeded,
          else: :token_budget_exceeded

      Repo.rollback(
        {code, max(1, DateTime.diff(DateTime.add(bucket.window, 3600), now, :second))}
      )
    end
  end

  defp increment(buckets, attrs) do
    for bucket <- buckets do
      Repo.update_all(from(b in Bucket, where: b.id == ^bucket.id), [inc: attrs], log: false)
    end
  end

  defp update_record(struct, attrs),
    do: struct |> Ecto.Changeset.change(attrs) |> Repo.update!(log: false)

  defp resource_access(%Scope{} = scope, agent, model) do
    case Access.authorize(scope, "ai.use", %{agent: agent, model: model}) do
      {:ok, _} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp resource_access(%Principal{agent_id: id}, selected, _),
    do: if(selected in [nil, id], do: :ok, else: {:error, :forbidden})

  defp resources(%Principal{} = p, _), do: {p.organization_id, p.agent_id}
  defp resources(%Scope{} = s, agent), do: {s.organization.id, agent}
end
