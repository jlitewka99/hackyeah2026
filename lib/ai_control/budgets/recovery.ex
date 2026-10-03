defmodule AiControl.Budgets.Recovery do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    case AiControl.Repo.query("SELECT to_regclass('budget_reservations')", [], log: false) do
      {:ok, %{rows: [[nil]]}} -> :ok
      {:ok, _} -> AiControl.Budgets.recover()
      _ -> :ok
    end

    {:ok, nil}
  end
end
