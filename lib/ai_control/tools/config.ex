defmodule AiControl.Tools.Config do
  @moduledoc "Operator-owned sandbox configuration, never populated from request parameters."
  def get, do: Application.get_env(:ai_control, __MODULE__, [])
  def timeout, do: Keyword.get(get(), :execution_timeout, 10_000)
  def sandboxes, do: Keyword.get(get(), :sandboxes, %{})

  def validate! do
    if !is_map(sandboxes()) || !(is_integer(timeout()) && timeout() in 1..10_000),
      do: raise(ArgumentError, "invalid tool configuration")

    :ok
  end

  def options(org, config) do
    with {:ok, org} <- Ecto.UUID.cast(org),
         true <- is_map(config),
         contexts when is_map(contexts) <- config["contexts"],
         true <- Enum.all?(contexts, fn {agent, context} -> uuid?(agent) && uuid?(context) end),
         grants when is_map(grants) <- Map.get(config, "grants", %{}),
         true <- Enum.all?(Map.keys(grants), &uuid?/1),
         true <- is_map(Map.get(config, "files", %{})) && is_map(Map.get(config, "tables", %{})) do
      {:ok,
       [
         organization_id: org,
         contexts: contexts,
         grants: normalize_grants(grants),
         files: Map.get(config, "files", %{}),
         tables: Map.get(config, "tables", %{}),
         name: via(org)
       ]}
    else
      _ -> {:error, :invalid_tool_configuration}
    end
  rescue
    _ -> {:error, :invalid_tool_configuration}
  end

  def via(org), do: {:via, Registry, {AiControl.Tools.Registry, org}}
  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp valid_grant?(grant) when is_map(grant) do
    Enum.all?(~w(paths tables recipients commands), fn key ->
      values = Map.get(grant, key, [])
      is_list(values) && Enum.all?(values, &(is_binary(&1) && String.valid?(&1)))
    end) && is_map(Map.get(grant, "endpoints", %{}))
  end

  defp valid_grant?(_), do: false

  defp normalize_grants(grants) do
    Map.new(grants, fn {agent, grant} ->
      if !valid_grant?(grant), do: raise(ArgumentError, "invalid tool grants")

      endpoints =
        Map.new(Map.get(grant, "endpoints", %{}), fn {url, endpoint} ->
          {:ok, ip} = :inet.parse_strict_address(String.to_charlist(endpoint["ip"]))
          {url, %{ip: ip, allow_private?: endpoint["allow_private"] == true}}
        end)

      {agent,
       %{
         paths: Map.get(grant, "paths", []),
         tables: Map.get(grant, "tables", []),
         recipients: Map.get(grant, "recipients", []),
         commands: Map.get(grant, "commands", []),
         endpoints: endpoints
       }}
    end)
  end
end
