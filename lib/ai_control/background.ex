defmodule AiControl.Background do
  @moduledoc "Authorized, durable background work, isolated from synchronous security decisions."
  import Ecto.Query, except: [update: 2]

  alias AiControl.Accounts.{Scope, User}
  alias AiControl.Audit.{Filters, WorkflowVisibility}
  alias AiControl.Background.{CaseResult, Chunk, Run}
  alias AiControl.Guards.Feeds
  alias AiControl.{Organizations, Repo}
  alias AiControl.Organizations.Access

  @active ~w(queued running retrying)
  @kinds ~w(audit_export metrics_report audit_enrichment gateway_tests benchmark guard_refresh)
  def kinds, do: @kinds
  def active?(run), do: run.status in @active

  def results_expired?(%{expires_at: nil}), do: false
  def results_expired?(run), do: !DateTime.before?(DateTime.utc_now(), run.expires_at)

  @doc "Recovers auxiliary run status after a worker is killed outside its callback."
  def reconcile do
    for {job_state, status} <- [
          {"cancelled", "cancelled"},
          {"discarded", "failed"},
          {"completed", "failed"}
        ] do
      query =
        from(r in Run,
          join: j in Oban.Job,
          on: r.job_id == j.id,
          where: r.status in ^@active and j.state == ^job_state,
          select: r.organization_id
        )

      {_, organizations} =
        Repo.update_all(query,
          set: [
            status: status,
            error_code: "job_unavailable",
            completed_at: DateTime.utc_now(),
            expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
          ]
        )

      Enum.each(Enum.uniq(organizations), &notify/1)
    end

    :ok
  end

  def enqueue(scope, kind, attrs \\ %{}) do
    with true <- kind in @kinds,
         {:ok, spec, permissions} <- specification(kind, attrs),
         {:ok, current} <- authorize(scope, permissions) do
      key =
        digest(
          {current.organization.id, current.user.id, kind,
           canonical(specification_key(kind, spec, attrs))}
        )

      result = Repo.transact(fn -> enqueue_locked(current, kind, spec, permissions, key) end)

      if match?({:ok, _}, result), do: notify(current.organization.id)
      result
    else
      false -> {:error, :invalid_job}
      error -> error
    end
  rescue
    _ -> {:error, :queue_unavailable}
  end

  defp specification_key(kind, spec, attrs)
       when kind in ~w(audit_export metrics_report audit_enrichment) do
    if get_in(attrs, ["filters", "range"]) in [nil, "1h", "24h", "7d"] do
      update_in(
        spec,
        ["filters"],
        &(&1
          |> Map.drop(~w(from to))
          |> Map.put("range", get_in(attrs, ["filters", "range"]) || "24h"))
      )
    else
      spec
    end
  end

  defp specification_key(_, spec, _), do: spec

  defp canonical(map) when is_map(map),
    do: map |> Enum.map(fn {key, value} -> {key, canonical(value)} end) |> Enum.sort()

  defp canonical(value), do: value

  defp enqueue_locked(scope, kind, spec, permissions, key) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key], log: false)

    with {:ok, current} <- authorize(scope, permissions) do
      case Repo.one(from(r in Run, where: r.dedup_key == ^key and r.status in ^@active),
             log: false
           ) do
        nil -> insert_run(current, kind, spec, permissions, key)
        run -> {:ok, run}
      end
    end
  end

  def list(scope, kinds) when is_list(kinds) do
    with {:ok, current} <- authorize(scope, read_permissions(kinds)) do
      runs =
        Repo.all(
          from(r in Run,
            where: r.organization_id == ^current.organization.id and r.kind in ^kinds,
            order_by: [desc: r.inserted_at, desc: r.id],
            limit: 50
          ),
          log: false
        )

      {:ok,
       runs
       |> Enum.filter(&match?({:ok, _}, authorize(current, view_permissions(&1))))
       |> Enum.map(&visible_run/1)}
    end
  end

  def fetch(scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, current} <- Organizations.refresh_scope(scope),
         %Run{} = run <- Repo.get_by(Run, id: id, organization_id: current.organization.id),
         {:ok, _} <- authorize(current, view_permissions(run)) do
      {:ok, visible_run(run)}
    else
      _ -> {:error, :forbidden}
    end
  end

  def cases(scope, id) do
    with {:ok, run} <- fetch(scope, id) do
      if results_expired?(run) do
        {:ok, []}
      else
        {:ok,
         Repo.all(from(c in CaseResult, where: c.run_id == ^run.id, order_by: c.case_id),
           log: false
         )}
      end
    end
  end

  defp visible_run(run) do
    if results_expired?(run), do: %{run | result: %{}}, else: run
  end

  def cancel(scope, id) do
    with {:ok, run} <- fetch(scope, id),
         {:ok, _} <- authorize(scope, run.permissions),
         true <- active?(run) do
      {_, _} =
        Repo.update_all(from(r in Run, where: r.id == ^run.id and r.status in ^@active),
          set: [
            status: "cancelled",
            error_code: "cancelled",
            completed_at: DateTime.utc_now(),
            expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
          ]
        )

      if run.job_id, do: Oban.cancel_job(run.job_id)
      notify(run.organization_id)
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorized_run(run) do
    with %Run{} = stored <- Repo.get(Run, run.id),
         true <- active?(stored),
         %User{} = user <- Repo.get(User, stored.user_id),
         {:ok, scope} <- Organizations.fetch_scope(Scope.for_user(user), stored.organization_id),
         {:ok, _} <- authorize(scope, stored.permissions),
         true <-
           stored.kind != "audit_export" || WorkflowVisibility.export_scope?(scope, stored.spec) do
      {:ok, stored, scope}
    else
      _ -> {:error, :access_revoked}
    end
  end

  def work(job, callback) do
    case job_run(job) do
      {:ok, run} ->
        if run.status == "completed" do
          :ok
        else
          execute_job(job, run, callback)
        end

      _ ->
        {:cancel, :invalid_job}
    end
  rescue
    _ -> fail_job(job, :job_unavailable)
  catch
    :exit, _ -> fail_job(job, :job_unavailable)
  end

  def update(run, attrs) do
    with {:ok, _, _} <- authorized_run(run) do
      {count, _} =
        Repo.update_all(from(r in Run, where: r.id == ^run.id and r.status in ^@active),
          set: Keyword.put(attrs, :updated_at, DateTime.utc_now())
        )

      if count == 1, do: notify(run.organization_id)
      if count == 1, do: {:ok, Repo.get!(Run, run.id)}, else: {:error, :access_revoked}
    end
  end

  def complete(run, result \\ %{}) do
    update(run,
      status: "completed",
      result: result,
      completed_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 7, :day),
      error_code: nil
    )
  end

  def put_chunk(run, position, data) when is_binary(data) do
    with {:ok, _, _} <- authorized_run(run) do
      Repo.insert_all(Chunk, [%{run_id: run.id, position: position, data: data}],
        on_conflict: :nothing,
        conflict_target: [:run_id, :position],
        log: false
      )

      :ok
    end
  end

  def chunk_page(scope, id, after_position \\ -1) do
    with {:ok, run} <- artifact(scope, id) do
      {:ok,
       Repo.all(
         from(c in Chunk,
           where: c.run_id == ^run.id and c.position > ^after_position,
           order_by: c.position,
           limit: 1
         ),
         log: false
       )}
    end
  end

  def artifact(scope, id) do
    with {:ok, run} <- fetch(scope, id),
         {:ok, current} <- authorize(scope, download_permissions(run)),
         true <- run.kind != "audit_export" || WorkflowVisibility.export_scope?(current, run.spec),
         true <- run.status == "completed" && not is_nil(run.expires_at),
         true <- DateTime.before?(DateTime.utc_now(), run.expires_at) do
      {:ok, run}
    else
      _ -> {:error, :artifact_unavailable}
    end
  end

  def checksum(run) do
    Repo.transaction(
      fn ->
        from(c in Chunk, where: c.run_id == ^run.id, order_by: c.position, select: c.data)
        |> Repo.stream(max_rows: 1, log: false)
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)
      end,
      log: false
    )
  end

  def notify(org) do
    if !Repo.in_transaction?() && Process.whereis(AiControl.PubSub) do
      Phoenix.PubSub.broadcast(
        AiControl.PubSub,
        "organizations:#{org}:background",
        :background_changed
      )
    end

    :ok
  end

  def authorize(scope, permissions) do
    Enum.reduce_while(permissions, {:ok, scope}, &authorize_permission/2)
  end

  defp authorize_permission(permission, {:ok, current}) do
    case Access.authorize(current, permission) do
      {:ok, %{organization: %{status: :active}} = fresh} -> {:cont, {:ok, fresh}}
      _ -> {:halt, {:error, :forbidden}}
    end
  end

  def worker("audit_export"), do: AiControl.Background.Workers.AuditExport
  def worker("metrics_report"), do: AiControl.Background.Workers.MetricsReport
  def worker("audit_enrichment"), do: AiControl.Background.Workers.AuditEnrichment
  def worker("guard_refresh"), do: AiControl.Background.Workers.GuardRefresh
  def worker("gateway_tests"), do: AiControl.Background.Workers.GatewayTests
  def worker("benchmark"), do: AiControl.Background.Workers.GatewayTests

  defp insert_run(scope, kind, spec, permissions, key) do
    with {:ok, run} <-
           Repo.insert(
             %Run{
               organization_id: scope.organization.id,
               user_id: scope.user.id,
               kind: kind,
               spec: spec,
               permissions: permissions,
               dedup_key: key
             },
             log: false
           ),
         args = %{
           "run_id" => run.id,
           "organization_id" => run.organization_id,
           "user_id" => run.user_id
         },
         {:ok, job} <- Oban.insert(worker(kind).new(args)) do
      Repo.update(Ecto.Changeset.change(run, job_id: job.id), log: false)
    end
  end

  defp specification(kind, attrs) when kind in ~w(audit_export metrics_report audit_enrichment) do
    with {:ok, filters} <- Filters.parse(Map.get(attrs, "filters", %{})) do
      spec = %{"filters" => filters |> Filters.params() |> Map.put("range", "custom")}
      budget? = kind == "metrics_report" && attrs["include_budgets"] in [true, "true"]

      permissions =
        ["events.read"] ++
          if(kind == "audit_export", do: ["events.export"], else: []) ++
          if(budget?, do: ["budgets.read"], else: [])

      {:ok, Map.put(spec, "include_budgets", budget?), permissions}
    end
  end

  defp specification(kind, attrs) when kind in ~w(gateway_tests benchmark) do
    suite =
      if kind == "benchmark", do: "semantic-pl.v1", else: Map.get(attrs, "suite", "gateway.v1")

    mode = Map.get(attrs, "mode", "controlled")

    if suite in ~w(gateway.v1 semantic-pl.v1) && mode in ~w(controlled live) &&
         (kind != "benchmark" || mode == "live") do
      {:ok, %{"suite" => suite, "mode" => mode}, ["tests.read", "tests.run"]}
    else
      {:error, :invalid_job}
    end
  end

  defp specification("guard_refresh", attrs) do
    if attrs["package"] in Feeds.package_ids(),
      do: {:ok, %{"package" => attrs["package"]}, ["signatures.read", "signatures.manage"]},
      else: {:error, :invalid_package}
  end

  defp read_permissions(kinds), do: kinds |> Enum.flat_map(&read_permission/1) |> Enum.uniq()
  defp read_permission(kind) when kind in ~w(gateway_tests benchmark), do: ["tests.read"]
  defp read_permission("guard_refresh"), do: ["signatures.read"]
  defp read_permission(_), do: ["events.read"]

  defp view_permissions(%{spec: %{"include_budgets" => true}} = run),
    do: read_permission(run.kind) ++ ["budgets.read"]

  defp view_permissions(run), do: read_permission(run.kind)
  defp download_permissions(run) when run.kind in ~w(gateway_tests benchmark), do: ["tests.read"]
  defp download_permissions(run), do: run.permissions

  defp digest(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)

  defp job_run(%{
         id: id,
         args: %{"run_id" => run_id, "organization_id" => org, "user_id" => user} = args
       })
       when map_size(args) == 3 do
    case Repo.get_by(Run, id: run_id, organization_id: org, user_id: user, job_id: id) do
      nil -> {:error, :invalid_job}
      run -> {:ok, run}
    end
  end

  defp job_run(_), do: {:error, :invalid_job}

  defp execute_job(job, run, callback) do
    with {:ok, _, scope} <- authorized_run(run),
         {:ok, run} <-
           update(run, status: "running", started_at: run.started_at || DateTime.utc_now()),
         {:ok, result} <- callback.(run, scope),
         {:ok, _} <- complete(run, result) do
      :ok
    else
      {:error, code} -> fail_job(job, code)
      _ -> fail_job(job, :job_unavailable)
    end
  end

  defp fail_job(job, code) do
    case job_run(job) do
      {:ok, run} -> mark_failure(job, run, code)
      _ -> {:cancel, "invalid_job"}
    end
  rescue
    _ -> {:cancel, "invalid_job"}
  end

  defp mark_failure(job, run, code) do
    cancelled? = code in [:access_revoked, :forbidden, :cancelled]

    terminal? = terminal?(job, code, cancelled?)

    status =
      cond do
        cancelled? -> "cancelled"
        terminal? -> "failed"
        true -> "retrying"
      end

    error_code =
      if code in ~w(access_revoked forbidden cancelled runner_unavailable invalid_package invalid_feed artifact_too_large runner_timeout runner_failed invalid_result)a,
        do: Atom.to_string(code),
        else: "job_unavailable"

    Repo.update_all(from(r in Run, where: r.id == ^run.id and r.status in ^@active),
      set: [
        status: status,
        error_code: error_code,
        completed_at: if(terminal?, do: DateTime.utc_now()),
        expires_at: if(terminal?, do: DateTime.add(DateTime.utc_now(), 7, :day))
      ]
    )

    notify(run.organization_id)
    if terminal?, do: {:cancel, error_code}, else: {:error, error_code}
  end

  defp terminal?(job, code, cancelled?),
    do:
      cancelled? || job.attempt >= job.max_attempts ||
        code in [:runner_unavailable, :invalid_package, :invalid_feed, :artifact_too_large]
end
