defmodule AiControl.Tools do
  @moduledoc "Verified-agent tool firewall with durable, audited sandbox execution."
  alias AiControl.ApiKeys.Principal
  alias AiControl.Policies
  alias AiControl.Policy.Snapshot
  alias AiControl.Security.Validation
  alias AiControl.Tools.{Executor, Sandbox, ToolRequest}

  def execute(identity, params, opts \\ []), do: Executor.execute(identity, params, opts)

  @doc "Discover metadata using a fresh policy snapshot, without exposing sandbox content."
  def catalog(%Principal{} = identity) do
    with {:ok, policy, current} <- Policies.snapshot_for_models(identity, nil),
         [{server, _}] <- Registry.lookup(AiControl.Tools.Registry, current.organization_id),
         {:ok, catalog} <- Sandbox.catalog(server, current, policy),
         {:ok, _} <- Policies.refresh_identity(current) do
      {:ok, catalog}
    else
      [] -> {:ok, %{tools: [], resources: [], policy_checksum: nil}}
      error -> error
    end
  catch
    :exit, _ -> {:error, :tool_unavailable}
  end

  def catalog(_), do: {:error, :forbidden}

  def prepare(%Principal{} = identity, params) do
    with true <- identity_valid?(identity),
         {:ok, policy, current} <- Policies.snapshot_for_models(identity, nil),
         {:ok, request} <- ToolRequest.new(current, params, policy),
         :ok <- authorize(request) do
      {:ok, request}
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  def prepare(_, _), do: {:error, :forbidden}

  @doc "Recheck live identity before effects, retaining the request's policy snapshot."
  def authorize(%ToolRequest{} = request) do
    with true <- identifiers?(request) && Snapshot.valid?(request.policy),
         {:ok, _} <- Policies.refresh_identity(ToolRequest.principal(request)),
         :ok <- ToolRequest.validate_arguments(request.tool, request.arguments) do
      settings = request.policy.settings || %{}
      agents = Map.get(settings, "allowed_agents", [])
      tools = get_in(settings, ["tools", "allowed_tools"]) || []

      if (agents == ["*"] || request.agent_id in agents) && request.tool in tools,
        do: :ok,
        else: {:error, :tool_not_allowed}
    else
      false -> {:error, :policy_unavailable}
      error -> error
    end
  end

  def authorize(_), do: {:error, :forbidden}

  defp identifiers?(request), do: Validation.uuid?(request.request_id) && identity_valid?(request)

  defp identity_valid?(identity),
    do:
      Enum.all?(
        [identity.organization_id, identity.agent_id, identity.api_key_id],
        &Validation.uuid?/1
      )
end
