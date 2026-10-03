defmodule AiControl.TestGatewayGuard do
  @moduledoc false
  @behaviour AiControl.Gateway.Guard

  @impl true
  def assess(fields, context, config), do: config[:test_guard].(fields, context)
  @impl true
  def ready?(_), do: true
end
