defmodule AiControl.Tools.ToolRequest do
  @moduledoc "Tool arguments bound to verified agent identity and one immutable policy snapshot."
  alias AiControl.ApiKeys.Principal
  alias AiControl.Tools.Catalog

  @derive {Inspect, only: [:request_id, :organization_id, :agent_id, :tool]}
  @enforce_keys [
    :request_id,
    :organization_id,
    :agent_id,
    :api_key_id,
    :tool,
    :arguments,
    :policy
  ]
  defstruct @enforce_keys

  def new(%Principal{} = identity, params, policy)
      when is_map(params) and not is_struct(params) do
    with true <- MapSet.new(Map.keys(params)) == MapSet.new(~w(tool arguments)),
         :ok <- Catalog.validate(params["tool"], params["arguments"]),
         :ok <- size_limit(params) do
      {:ok,
       %__MODULE__{
         request_id: Ecto.UUID.generate(),
         organization_id: identity.organization_id,
         agent_id: identity.agent_id,
         api_key_id: identity.api_key_id,
         tool: params["tool"],
         arguments: params["arguments"],
         policy: policy
       }}
    else
      false -> {:error, :invalid_tool_request}
      error -> error
    end
  end

  def new(_, _, _), do: {:error, :invalid_tool_request}

  defp size_limit(params) do
    if byte_size(Jason.encode!(params)) <= 65_536,
      do: :ok,
      else: {:error, :tool_request_too_large}
  end

  def principal(request) do
    %Principal{
      organization_id: request.organization_id,
      agent_id: request.agent_id,
      api_key_id: request.api_key_id
    }
  end
end
