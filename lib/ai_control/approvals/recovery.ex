defmodule AiControl.Approvals.Recovery do
  @moduledoc "Startup reconciliation never retries a claimed or dispatched operation."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    :ok = AiControl.Approvals.reconcile(true)
    {:ok, nil}
  end
end
