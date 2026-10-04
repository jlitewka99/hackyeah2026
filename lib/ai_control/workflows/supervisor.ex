defmodule AiControl.Workflows.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: AiControl.Workflows.Registry},
        {DynamicSupervisor, name: AiControl.Workflows.DynamicSupervisor, strategy: :one_for_one},
        {Task.Supervisor, name: AiControl.Workflows.Tasks},
        AiControl.Workflows.Manager
      ],
      strategy: :one_for_all
    )
  end
end
