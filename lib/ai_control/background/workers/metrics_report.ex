defmodule AiControl.Background.Workers.MetricsReport do
  @moduledoc "Reproducible report artifacts using the dashboard projections and a fixed audit range."
  use Oban.Worker, queue: :reports, max_attempts: 3

  alias AiControl.Audit.Filters
  alias AiControl.{Background, Dashboard, Repo}
  alias AiControl.Background.Chunk

  @impl true
  def perform(job), do: Background.work(job, &report/2)

  def report(run, scope) do
    case Repo.get_by(Chunk, run_id: run.id, position: 0) do
      nil ->
        generate(run, scope)

      chunk ->
        with {:ok, result} <- Jason.decode(chunk.data),
             {:ok, checksum} <- Background.checksum(run),
             {:ok, _} <- Background.update(run, checksum: checksum),
             do: {:ok, result}
    end
  end

  defp generate(run, scope) do
    Repo.transact(fn -> generate_snapshot(run, scope) end)
  end

  defp generate_snapshot(run, scope) do
    with {:ok, filters} <- Filters.parse(run.spec["filters"]),
         {:ok, activity} <- Dashboard.activity(scope, filters),
         {:ok, budgets} <- budget(scope, run.spec["include_budgets"]) do
      result = %{
        "generated_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "range" => run.spec["filters"],
        "counts" => activity.counts,
        "operations" => activity.operations,
        "latencies" => activity.latencies,
        "detections" => activity.detections,
        "errors" => activity.errors,
        "budgets" => budgets,
        "latency_unit" => "microseconds"
      }

      with :ok <- Background.put_chunk(run, 0, Jason.encode!(result) <> "\n"),
           {:ok, checksum} <- Background.checksum(run),
           {:ok, _} <- Background.update(run, checksum: checksum),
           do: {:ok, result}
    end
  end

  defp budget(_, false), do: {:ok, nil}

  defp budget(scope, true) do
    with {:ok, value} <- Dashboard.budgets(scope) do
      {:ok,
       %{
         window: value.window,
         ends_at: value.ends_at,
         costs: value.costs,
         statuses: value.statuses,
         organization: Map.take(value.bucket, [:requests, :tokens, :reserved, :unbounded]),
         agents: value.agents
       }}
    end
  end
end
