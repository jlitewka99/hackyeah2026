defmodule AiControl.Background.Telemetry do
  @moduledoc "Projects Oban telemetry into bounded labels, dropping job arguments and identities."
  import Ecto.Query

  alias AiControl.{Background, Repo}

  @queues ~w(reports tests maintenance)
  @states ~w(available scheduled executing retryable)
  def install do
    :telemetry.detach(__MODULE__)

    :telemetry.attach_many(
      __MODULE__,
      [[:oban, :job, :stop], [:oban, :job, :exception]],
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle(event, measurements, %{job: job} = metadata, _) do
    if job.queue in @queues do
      status =
        if List.last(event) == :exception || metadata[:state] in [:failure, :discard],
          do: "error",
          else: "finished"

      :telemetry.execute(
        [:ai_control, :background, :job],
        %{count: 1, duration: measurements[:duration] || 0, wait: measurements[:queue_time] || 0},
        %{queue: job.queue, status: status}
      )
    end
  end

  def handle(_, _, _, _), do: :ok

  def poll do
    Background.reconcile()

    counts =
      Repo.all(
        from(j in Oban.Job,
          where: j.queue in ^@queues and j.state in ^@states,
          group_by: [j.queue, j.state],
          select: {j.queue, j.state, count(j.id)}
        ),
        log: false
      )
      |> Map.new(fn {queue, state, count} -> {{queue, state}, count} end)

    for queue <- @queues, state <- @states do
      count = Map.get(counts, {queue, state}, 0)

      :telemetry.execute([:ai_control, :background, :queue], %{count: count}, %{
        queue: queue,
        state: state
      })
    end
  rescue
    _ -> :ok
  end
end
