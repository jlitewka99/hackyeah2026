defmodule AiControl.Tools.Discovery do
  @moduledoc "Content-free discovery intersecting one policy snapshot with live sandbox resources."
  alias AiControl.Tools.{Catalog, Resources, ToolRequest}

  def catalog(identity, policy, state) do
    if identity.organization_id == state.organization_id &&
         match?({:ok, _}, Ecto.UUID.cast(state.contexts[identity.agent_id])) do
      grant = Map.get(state.grants, identity.agent_id, %{})
      allowed = get_in(policy.settings, ["tools", "allowed_tools"]) || []

      tools = tools(identity, policy, allowed, grant, state)

      resources = resources(identity, policy, tools, grant, state.files)

      {:ok, %{tools: tools, resources: resources, policy_checksum: policy.checksum}}
    else
      {:ok, %{tools: [], resources: [], policy_checksum: policy.checksum}}
    end
  end

  def uri(path), do: "aicontrol://sandbox/files/" <> Base.url_encode64(path, padding: false)

  defp tools(identity, policy, allowed, grant, state) do
    Enum.filter(Catalog.all(), fn tool ->
      tool["name"] in allowed &&
        Enum.any?(candidates(tool["name"], grant, state), fn args ->
          accessible?(identity, policy, tool["name"], args, grant, state.files)
        end)
    end)
  end

  defp resources(identity, policy, tools, grant, files) do
    if Enum.any?(tools, &(&1["name"] == "file.read")) do
      files
      |> Enum.filter(fn {path, content} ->
        is_binary(content) && String.valid?(content) &&
          accessible?(identity, policy, "file.read", %{"path" => path}, grant, files)
      end)
      |> Enum.map(fn {path, _} -> %{path: path, uri: uri(path)} end)
      |> Enum.sort_by(& &1.uri)
    else
      []
    end
  end

  defp accessible?(identity, policy, tool, args, grant, files) do
    request = %ToolRequest{
      request_id: Ecto.UUID.generate(),
      organization_id: identity.organization_id,
      agent_id: identity.agent_id,
      api_key_id: identity.api_key_id,
      policy: policy,
      tool: tool,
      arguments: args
    }

    Catalog.validate(tool, args) == :ok &&
      match?({:ok, _}, Resources.authorize(request, grant, files))
  end

  defp candidates(tool, grant, state) when tool in ~w(file.read file.write file.delete) do
    grant
    |> Map.get(:paths, [])
    |> Enum.filter(&(tool == "file.write" || is_binary(state.files[&1])))
    |> Enum.map(fn path ->
      if tool == "file.write", do: %{"path" => path, "content" => ""}, else: %{"path" => path}
    end)
  end

  defp candidates("http.get", grant, _),
    do: Enum.map(Map.keys(Map.get(grant, :endpoints, %{})), &%{"url" => &1})

  defp candidates("database.select", grant, state),
    do:
      grant
      |> Map.get(:tables, [])
      |> Enum.filter(&Map.has_key?(state.tables, &1))
      |> Enum.map(&%{"table" => &1, "limit" => 1})

  defp candidates("email.send", grant, _),
    do:
      Enum.map(Map.get(grant, :recipients, []), fn recipient ->
        %{"recipient" => recipient, "subject" => "Discovery", "body" => ""}
      end)

  defp candidates("command.run", grant, _),
    do:
      Enum.map(Map.get(grant, :commands, []), fn command ->
        %{"command" => command, "arguments" => if(command == "echo", do: ["Discovery"], else: [])}
      end)
end
