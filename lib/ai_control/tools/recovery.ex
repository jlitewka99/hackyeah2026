defmodule AiControl.Tools.Recovery do
  @moduledoc false
  use GenServer

  alias AiControl.Tools.Executions

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    case AiControl.Repo.query("SELECT to_regclass('tool_executions')", [], log: false) do
      {:ok, %{rows: [[nil]]}} ->
        {:ok, nil}

      {:ok, _} ->
        case Executions.recover() do
          {:ok, :ok} -> {:ok, nil}
          _ -> {:stop, :tool_recovery_unavailable}
        end

      _ ->
        {:stop, :tool_recovery_unavailable}
    end
  end
end
