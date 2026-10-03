defmodule AiControl.Organizations.ResourceResolver do
  @moduledoc "Ownership adapter for agent and model registries added in later roadmap steps."
  @callback owned?(String.t(), :agent | :model, String.t()) :: boolean()
  def owned?(organization_id, kind, key) do
    case Application.get_env(:ai_control, :organization_resource_resolver) do
      nil -> false
      resolver -> resolver.owned?(organization_id, kind, key)
    end
  end
end
