defmodule AiControl.TestPolicyResourceResolver do
  @moduledoc false
  @behaviour AiControl.Organizations.ResourceResolver

  @impl true
  def owned?(organization_id, :agent, key), do: AiControl.Agents.owned?(organization_id, key)
  def owned?(_, :model, key), do: key in ["qwen3.5:4b", "catalog-model"]
end
