defmodule AiControl.Background.Workers.AuditExport do
  @moduledoc "Manifest-backed committed JSONL export with durable batch checkpoints."
  use Oban.Worker, queue: :reports, max_attempts: 3

  import Ecto.Query

  alias AiControl.Audit.{Event, Filters, Serializer, WorkflowVisibility}
  alias AiControl.{Background, Repo}
  alias AiControl.Background.{ExportEvent, Run}

  @impl true
  def perform(job), do: Background.work(job, &export/2)

  defp export(run, _scope) do
    with {:ok, run} <- manifest(run),
         :ok <- batches(run),
         :ok <-
           Background.put_chunk(
             run,
             run.total + 1,
             Jason.encode!(%{type: "export_complete", schema_version: 1, count: run.total}) <>
               "\n"
           ),
         {:ok, checksum} <- Background.checksum(run),
         {:ok, _} <- Background.update(run, checksum: checksum) do
      {:ok, %{"count" => run.total, "format" => "jsonl"}}
    end
  end

  defp manifest(%{manifest_ready: true} = run), do: {:ok, run}

  defp manifest(run) do
    Repo.transact(fn -> freeze_manifest(run) end)
  end

  defp freeze_manifest(run) do
    locked = Repo.one!(from(r in Run, where: r.id == ^run.id, lock: "FOR UPDATE"), log: false)

    with {:ok, _, scope} <- Background.authorized_run(locked) do
      if locked.manifest_ready do
        {:ok, locked}
      else
        {:ok, filters} = Filters.parse(locked.spec["filters"])
        query = Filters.query(locked.organization_id, filters) |> WorkflowVisibility.query(scope)

        {sql, params} =
          Repo.to_sql(:all, from(e in query, select: %{id: e.id, occurred_at: e.occurred_at}))

        {params, param} = {params ++ [Ecto.UUID.dump!(locked.id)], length(params) + 1}

        %{num_rows: count} =
          Repo.query!(
            "INSERT INTO background_export_events (run_id, position, event_id) SELECT $#{param}::uuid, row_number() OVER (ORDER BY occurred_at, id), id FROM (#{sql}) AS committed",
            params,
            log: false
          )

        Background.update(locked,
          total: count,
          manifest_ready: true,
          spec: Map.put(locked.spec, "workflow_agents", scope.grants.agents)
        )
      end
    end
  end

  defp batches(run) do
    with {:ok, run, scope} <- Background.authorized_run(run) do
      events =
        from(e in Event,
          join: m in ExportEvent,
          on: m.event_id == e.id,
          where: m.run_id == ^run.id and m.position > ^run.cursor,
          order_by: m.position,
          limit: 500,
          select: {m.position, e}
        )
        |> WorkflowVisibility.query(scope)
        |> Repo.all(log: false)

      case events do
        [] ->
          :ok

        _ ->
          {last, _} = List.last(events)

          data = Enum.map_join(events, &serialize_event/1)

          result = save_checkpoint(run, last, data)

          resume(result, run)
      end
    end
  end

  defp serialize_event({_, event}),
    do: Jason.encode!(%{type: "event", schema_version: 1, event: Serializer.event(event)}) <> "\n"

  defp resume({:ok, next}, run) do
    Background.notify(run.organization_id)
    batches(next)
  end

  defp resume(error, _), do: error

  defp checkpoint(run, last, data) do
    with :ok <- Background.put_chunk(run, last, data),
         do: Background.update(run, cursor: last, progress: last)
  end

  defp save_checkpoint(run, last, data), do: Repo.transact(fn -> checkpoint(run, last, data) end)
end
