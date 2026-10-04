defmodule AiControl.Gateway.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    Supervisor.init(
      [
        {Task.Supervisor, name: AiControl.Gateway.Tasks},
        {DynamicSupervisor, name: AiControl.Gateway.Streams},
        AiControl.Gateway.Slots
      ],
      strategy: :one_for_all
    )
  end
end
