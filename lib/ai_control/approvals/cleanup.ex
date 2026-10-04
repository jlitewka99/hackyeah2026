defmodule AiControl.Approvals.Cleanup do
  @moduledoc "Expiry is checked synchronously; this job erases unused expired previews."
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl true
  def perform(_), do: AiControl.Approvals.reconcile()
end
