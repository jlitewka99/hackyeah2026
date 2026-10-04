defmodule AiControl.Testing.UnavailableGuard do
  @moduledoc false
  @behaviour AiControl.Gateway.Guard

  @impl true
  def assess(_, _, _, _), do: {:error, :guard_unavailable}
  @impl true
  def ready?(_), do: false
end
