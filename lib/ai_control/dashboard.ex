defmodule AiControl.Dashboard do
  @moduledoc "Tenant-scoped reporting from durable audit evidence and current UTC accounting."
  import Ecto.Query

  alias AiControl.Agents.Agent
  alias AiControl.Audit.Filters
  alias AiControl.{Budgets, Policies, Repo}
  alias AiControl.Budgets.{Bucket, Reservation}
  alias AiControl.Organizations.Access

  def overview(scope, filters) do
    %{
      activity: activity(scope, filters),
      budgets: budgets(scope),
      policy: Policies.current(scope)
    }
  end

  def activity(scope, filters) do
    with {:ok, current} <- Access.authorize(scope, "events.read") do
      query = Filters.query(current.organization.id, filters)
      {sql, params} = Repo.to_sql(:all, query)

      prefix =
        "WITH events AS (#{sql}), terminal AS (SELECT DISTINCT ON (request_id) * FROM events WHERE kind = 'gateway' ORDER BY request_id, occurred_at DESC, id DESC) "

      outcomes =
        Repo.query!(
          prefix <>
            """
            SELECT CASE
            WHEN reason_codes::text[] @> ARRAY['completed']::text[]
            THEN CASE WHEN EXISTS (SELECT 1
            FROM audit_events d
            WHERE d.organization_id = t.organization_id AND d.request_id = t.request_id AND d.action = 'redact') THEN 'redact'
            ELSE 'allow' END
            WHEN reason_codes::text[] @> ARRAY['policy_blocked']::text[] THEN 'block'
            WHEN reason_codes::text[] && ARRAY['request_budget_exceeded','token_budget_exceeded','tool_budget_exceeded']::text[] THEN 'budget_denied'
            WHEN event_type = 'gateway.failed' OR reason_codes::text[] && ARRAY['budget_unavailable','tokenizer_unavailable','budget_conflict']::text[] THEN 'service_error'
            ELSE 'rejected'
            END AS outcome, count(*)
            FROM terminal t
            GROUP BY outcome
            """,
          params,
          log: false
        )

      counts =
        Map.merge(
          Map.new(~w(allow redact block budget_denied service_error rejected), &{&1, 0}),
          Map.new(outcomes.rows, fn [key, count] -> {key, count} end)
        )

      operations =
        Repo.query!(
          prefix <>
            "SELECT coalesce(data->>'operation', 'not_recorded'), count(*) FROM terminal GROUP BY 1",
          params,
          log: false
        )

      timings =
        Repo.query!(
          prefix <>
            """
            SELECT timing.key, percentile_disc(0.5)
            WITHIN GROUP (ORDER BY timing.value::bigint), percentile_disc(0.95)
            WITHIN GROUP (ORDER BY timing.value::bigint), count(*)
            FROM terminal
            CROSS JOIN LATERAL jsonb_each_text(COALESCE(data->'timings', '{}'::jsonb)) timing
            WHERE timing.value ~ '^[0-9]+$'
            GROUP BY timing.key
            ORDER BY timing.key
            """,
          params,
          log: false
        )

      latencies =
        Enum.map(timings.rows, fn [key, p50, p95, count] ->
          %{id: key, p50: p50, p95: p95, count: count}
        end)

      detections =
        Repo.query!(
          prefix <>
            """
            SELECT stage, guard, rule_id, count(*)
            FROM (SELECT DISTINCT request_id, stage, d->>'guard' AS guard, d->>'rule_id' AS rule_id
            FROM events
            CROSS JOIN LATERAL jsonb_array_elements(COALESCE(data->'detections','[]'::jsonb)) d
            WHERE kind = 'decision') findings
            GROUP BY stage, guard, rule_id
            ORDER BY count(*) DESC, stage, guard, rule_id
            """,
          params,
          log: false
        )

      findings =
        Enum.map(detections.rows, fn [stage, guard, rule, count] ->
          %{id: "#{stage}:#{guard}:#{rule}", stage: stage, guard: guard, rule: rule, count: count}
        end)

      errors =
        Repo.query!(
          prefix <>
            """
            SELECT code, count(*)
            FROM terminal
            CROSS JOIN LATERAL unnest(reason_codes) code
            WHERE event_type = 'gateway.failed' OR code IN ('budget_unavailable','budget_conflict','tokenizer_unavailable')
            GROUP BY code
            ORDER BY count(*) DESC, code
            """,
          params,
          log: false
        )

      recent =
        query
        |> order_by([e], desc: e.occurred_at, desc: e.id)
        |> limit(8)
        |> Repo.all(log: false)

      {:ok,
       %{
         counts: counts,
         total: Enum.sum(Map.values(counts)),
         operations: Map.new(operations.rows, fn [key, count] -> {key, count} end),
         latencies: latencies,
         detections: findings,
         errors: Enum.map(errors.rows, fn [code, count] -> %{id: code, count: count} end),
         recent: recent
       }}
    end
  rescue
    _ -> {:error, :report_unavailable}
  end

  def budgets(scope, now \\ DateTime.utc_now()) do
    with {:ok, current} <- Access.authorize(scope, "budgets.read"),
         {:ok, policy} <- Policies.summary(current, :budgets),
         {:ok, bucket} <- Budgets.state(current, nil, now) do
      window = Budgets.window(now)
      agents = from(a in Agent, where: a.organization_id == ^current.organization.id)

      agents =
        if "*" in current.grants.agents,
          do: agents,
          else: from(a in agents, where: a.id in ^current.grants.agents)

      agent_rows =
        Repo.all(
          from(a in agents,
            left_join: b in Bucket,
            on:
              b.organization_id == a.organization_id and b.subject_id == a.id and
                b.level == "agent" and b.window == ^window,
            order_by: [asc: a.name, asc: a.id],
            select: %{
              id: a.id,
              name: a.name,
              requests: coalesce(b.requests, 0),
              tokens: coalesce(b.tokens, 0),
              reserved: coalesce(b.reserved, 0),
              unbounded: coalesce(b.unbounded, 0)
            }
          ),
          log: false
        )

      receipts =
        from(r in Reservation,
          where: r.organization_id == ^current.organization.id and r.window == ^window
        )

      costs =
        Repo.all(
          from(r in receipts,
            group_by: fragment("?->>'currency'", r.price),
            select: %{
              currency: fragment("?->>'currency'", r.price),
              cost: sum(r.cost),
              not_configured: filter(count(r.id), is_nil(r.price)),
              unavailable: filter(count(r.id), not is_nil(r.price) and is_nil(r.cost))
            }
          ),
          log: false
        )

      statuses =
        Repo.all(from(r in receipts, group_by: r.status, select: {r.status, count(r.id)}),
          log: false
        )
        |> Map.new()

      {:ok,
       %{
         window: window,
         ends_at: DateTime.add(window, 3600),
         policy: policy,
         bucket: bucket || %Bucket{},
         agents: agent_rows,
         costs:
           Enum.with_index(costs, fn value, index -> Map.put(value, :id, "cost-#{index}") end),
         statuses: statuses
       }}
    end
  rescue
    _ -> {:error, :report_unavailable}
  end

  def signatures(scope) do
    with {:ok, current} <- Access.authorize(scope, "signatures.read"),
         {:ok, policy} <- Policies.summary(current, :signatures) do
      catalog = AiControl.Guards.Registry.catalog()

      signatures =
        catalog.rules
        |> Enum.filter(fn {id, _} -> String.starts_with?(id, "exploit.") end)
        |> Enum.sort()
        |> Enum.map(fn {id, rule} -> Map.put(rule, :id, id) end)

      {:ok,
       %{
         policy: policy,
         version: catalog.version,
         origin: catalog.origin,
         checksum: catalog.checksum,
         signatures: signatures
       }}
    end
  end

  def agent_summaries(scope, filters) do
    with {:ok, current} <- Access.authorize(scope, "events.read"),
         {:ok, agents} <- AiControl.Agents.list_agents(current) do
      ids = Enum.map(agents, & &1.id)
      query = Filters.query(current.organization.id, filters)

      query =
        from(e in query,
          where: e.kind == :gateway and e.agent_id in ^ids,
          distinct: e.request_id,
          order_by: [asc: e.request_id, desc: e.occurred_at, desc: e.id]
        )

      {sql, params} = Repo.to_sql(:all, query)

      rows =
        Repo.query!(
          """
          SELECT t.agent_id, count(*),
            count(*) FILTER (WHERE t.reason_codes::text[] @> ARRAY['policy_blocked']::text[]),
            count(*) FILTER (WHERE t.reason_codes::text[] @> ARRAY['completed']::text[] AND EXISTS (
              SELECT 1 FROM audit_events d WHERE d.organization_id = t.organization_id
              AND d.request_id = t.request_id AND d.action = 'redact'))
          FROM (#{sql}) t GROUP BY t.agent_id
          """,
          params,
          log: false
        )

      summaries = Map.new(ids, &{&1, %{total: 0, counts: %{"block" => 0, "redact" => 0}}})

      {:ok,
       Enum.reduce(rows.rows, summaries, fn [id, total, block, redact], acc ->
         Map.put(acc, Ecto.UUID.load!(id), %{
           total: total,
           counts: %{"block" => block, "redact" => redact}
         })
       end)}
    end
  end
end
