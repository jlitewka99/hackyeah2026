defmodule AiControl.Background.Workers.AuditEnrichment do
  @moduledoc "Reproducible derived summaries stored separately from primary audit evidence."
  use Oban.Worker, queue: :reports, max_attempts: 3

  alias AiControl.Background
  alias AiControl.Background.Workers.MetricsReport

  @impl true
  def perform(job), do: Background.work(job, &MetricsReport.report/2)
end
