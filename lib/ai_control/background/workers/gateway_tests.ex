defmodule AiControl.Background.Workers.GatewayTests do
  @moduledoc "Stores validated, attempt-local scenario projections from the isolated runner."
  use Oban.Worker, queue: :tests, max_attempts: 3

  import Ecto.Query

  alias AiControl.Background
  alias AiControl.Background.{CaseResult, Chunk}
  alias AiControl.Repo
  alias AiControl.Testing.ProcessExecutor
  alias AiControl.Testing.Suite

  @impl true
  def timeout(_), do: to_timeout(hour: 2) + to_timeout(minute: 5)

  @impl true
  def perform(job), do: Background.work(job, &execute/2)

  defp execute(run, _scope) do
    # A process restart runs the closed suite again; replace attempt-local projections.
    Repo.delete_all(from(c in CaseResult, where: c.run_id == ^run.id), log: false)
    Repo.delete_all(from(c in Chunk, where: c.run_id == ^run.id), log: false)
    {:ok, _} = Background.update(run, progress: 0, total: 0)

    with {:ok, count} <- ProcessExecutor.run(run, &store(run, &1)),
         :ok <- verify_complete(run, count),
         {:ok, checksum} <- Background.checksum(run),
         {:ok, _} <- Background.update(run, checksum: checksum, total: count) do
      counts =
        Repo.all(
          from(c in CaseResult,
            where: c.run_id == ^run.id,
            group_by: c.status,
            select: {c.status, count(c.id)}
          )
        )
        |> Map.new()

      {:ok,
       Map.merge(counts, %{
         "synthetic" => true,
         "mode" => run.spec["mode"],
         "suite" => run.spec["suite"],
         "cases" => count
       })}
    end
  end

  defp store(run, row) do
    if row["case_id"] in Suite.expected_ids(run.spec),
      do: persist(run, row),
      else: {:error, :invalid_result}
  end

  defp persist(run, row) do
    Repo.transact(fn -> store_case(run, row) end)
    |> case do
      {:ok, :ok} ->
        Background.notify(run.organization_id)
        :ok

      error ->
        error
    end
  end

  defp verify_complete(run, count) do
    ids =
      Repo.all(from(c in CaseResult, where: c.run_id == ^run.id, select: c.case_id), log: false)

    if count == length(ids) && Enum.sort(ids) == Enum.sort(Suite.expected_ids(run.spec)),
      do: :ok,
      else: {:error, :invalid_result}
  end

  defp store_case(run, row) do
    with {:ok, current, _} <- Background.authorized_run(run) do
      Repo.insert_all(
        CaseResult,
        [
          %{
            id: Ecto.UUID.generate(),
            run_id: run.id,
            case_id: row["case_id"],
            status: row["status"],
            duration_us: row["duration_us"],
            evidence: row["evidence"]
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:run_id, :case_id],
        log: false
      )

      with :ok <- Background.put_chunk(current, current.progress, Jason.encode!(row) <> "\n"),
           {:ok, _} <- Background.update(current, progress: current.progress + 1) do
        {:ok, :ok}
      end
    end
  end
end
