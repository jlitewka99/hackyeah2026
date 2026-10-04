defmodule AiControl.Guards.Moderation do
  @moduledoc "Response safety labels use a separate guard and policy category."
  @behaviour AiControl.Gateway.Guard

  alias AiControl.Guards.Semantic

  @impl true
  def assess(fields, context, snapshot, config),
    do: Semantic.assess_as("moderation", "moderation", fields, context, snapshot, config)

  @impl true
  def ready?(config), do: Semantic.ready?(Keyword.put(config, :injection_provider, "qwen"))
end
