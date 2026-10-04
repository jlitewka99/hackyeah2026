defmodule AiControl.Background.Workers.GuardRefresh do
  @moduledoc "Validate and register a candidate signature set without changing active controls."
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias AiControl.{Background, Guards.Feeds}

  @impl true
  def perform(job) do
    Background.work(job, fn run, scope ->
      with {:ok, set} <- Feeds.import_package(scope, run.spec["package"]) do
        {:ok,
         %{
           "set_id" => set.set_id,
           "version" => set.version,
           "checksum" => set.checksum,
           "activation" => "candidate"
         }}
      end
    end)
  end
end
