defmodule AiControl.Organizations.Access do
  @moduledoc "Current database-backed capability checks, including both AI resource dimensions."
  alias AiControl.Organizations
  alias AiControl.Organizations.{Grants, ResourceResolver}

  def authorize(scope, permission, resources \\ %{}) do
    with true <- permission in Grants.permissions(),
         {:ok, current} <- Organizations.refresh_scope(scope),
         true <- permission in current.grants.permissions,
         true <- resources_allowed?(current, permission, resources) do
      {:ok, current}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp resources_allowed?(scope, "ai.use", %{agent: agent, model: model}) do
    scope.organization.status == :active &&
      owned_and_granted?(scope, :agent, agent, scope.grants.agents) &&
      owned_and_granted?(scope, :model, model, scope.grants.models)
  end

  defp resources_allowed?(_, "ai.use", _), do: false

  defp resources_allowed?(scope, permission, %{agent: agent})
       when permission in ["agents.read", "agents.manage", "api_keys.read", "api_keys.manage"],
       do: owned_and_granted?(scope, :agent, agent, scope.grants.agents)

  defp resources_allowed?(_, _, resources), do: resources == %{}

  defp owned_and_granted?(scope, kind, key, selectors),
    do:
      is_binary(key) && ResourceResolver.owned?(scope.organization.id, kind, key) &&
        Grants.includes?(selectors, key)
end
