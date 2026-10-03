defmodule AiControl.Organizations.ResourceResolver do
  @moduledoc "Organization agent ownership and the operator model catalog."
  alias AiControl.Gateway.Models

  @callback owned?(String.t(), :agent | :model, String.t()) :: boolean()
  def owned?(organization_id, kind, key) do
    case Application.get_env(:ai_control, :organization_resource_resolver) do
      nil -> registered?(organization_id, kind, key)
      resolver -> resolver.owned?(organization_id, kind, key)
    end
  end

  defp registered?(organization_id, :agent, key),
    do: AiControl.Agents.owned?(organization_id, key)

  defp registered?(_, :model, key), do: Models.registered?(key)
end
