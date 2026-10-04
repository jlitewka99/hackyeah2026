defmodule AiControl.Tools.Supervisor do
  @moduledoc "Named tenant sandboxes start after receipt recovery and before the endpoint."
  use Supervisor

  alias AiControl.Tools.{Config, Sandbox}

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    :ok = Config.validate!()

    sandboxes =
      Enum.map(Config.sandboxes(), fn {org, config} ->
        {:ok, opts} = Config.options(org, config)
        Supervisor.child_spec({Sandbox, opts}, id: org)
      end)

    Supervisor.init(
      [
        {Registry, keys: :unique, name: AiControl.Tools.Registry},
        AiControl.Tools.Recovery
      ] ++ sandboxes,
      strategy: :one_for_all
    )
  end
end
