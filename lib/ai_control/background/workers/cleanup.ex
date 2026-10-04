defmodule AiControl.Background.Workers.Cleanup do
  @moduledoc "Retention applies only to background artifacts and run metadata."
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias AiControl.Background
  alias AiControl.Background.{CaseResult, Chunk, ExportEvent, Run}
  alias AiControl.Repo

  @impl true
  def perform(_job) do
    Background.reconcile()
    now = DateTime.utc_now()

    expired =
      from(r in Run,
        where: r.status in ~w(completed failed cancelled) and r.expires_at <= ^now,
        select: r.id
      )

    {:ok, organizations} =
      Repo.transact(fn ->
        organizations =
          Repo.all(from(r in Run, where: r.id in subquery(expired), select: r.organization_id),
            log: false
          )

        Repo.delete_all(from(c in Chunk, where: c.run_id in subquery(expired)))
        Repo.delete_all(from(e in ExportEvent, where: e.run_id in subquery(expired)))
        Repo.delete_all(from(c in CaseResult, where: c.run_id in subquery(expired)))
        Repo.update_all(from(r in Run, where: r.id in subquery(expired)), set: [result: %{}])

        Repo.update_all(
          from(r in Run, where: r.id in subquery(expired) and r.status == "completed"),
          set: [status: "expired"]
        )

        cutoff = DateTime.add(now, -30, :day)

        Repo.delete_all(
          from(r in Run,
            where: r.inserted_at < ^cutoff and r.status in ~w(completed failed cancelled expired)
          )
        )

        {:ok, Enum.uniq(organizations)}
      end)

    Enum.each(organizations, &Background.notify/1)
    :ok
  end
end
