defmodule AiControl.MCP do
  @moduledoc "MCP 2025-11-25 adapter. All content operations use the existing tool firewall."
  alias AiControl.MCP.{RPC, Sessions}
  alias AiControl.Tools

  @version "2025-11-25"
  @descriptions %{
    "file.read" => "Read an authorized virtual sandbox file.",
    "file.write" => "Create or replace an authorized virtual sandbox file.",
    "file.delete" => "Delete an authorized virtual sandbox file.",
    "http.get" => "Fetch an exact operator-approved HTTP endpoint.",
    "database.select" => "Read rows from an authorized sandbox table.",
    "email.send" => "Queue a message in the sandbox's local mailbox.",
    "command.run" => "Run an authorized sandbox command without a shell."
  }

  def version, do: @version

  def handle(identity, request, session, opts \\ []) do
    case RPC.validate(request) do
      {:ok, rpc} -> handle_rpc(identity, rpc, session, opts)
      {:error, error} -> reply(400, error)
    end
  end

  defp handle_rpc(identity, rpc, session, opts) do
    dispatch(identity, rpc, session, opts)
  rescue
    _ -> reply(500, RPC.error(rpc.id, -32_603, :internal_error))
  catch
    :exit, _ -> reply(503, RPC.error(rpc.id, -32_603, :gateway_unavailable))
  end

  def idempotency_key(session, id) do
    # Include the ID's type. The digest is namespaced and contains no request content.
    <<a::48, _::4, b::12, _::2, c::62, _::binary>> =
      :crypto.hash(:sha256, :erlang.term_to_binary({"ai-control.mcp.v1", session, id}))

    {:ok, uuid} = Ecto.UUID.load(<<a::48, 8::4, b::12, 2::2, c::62>>)
    uuid
  end

  defp dispatch(identity, %{method: "initialize", notification?: false} = rpc, nil, opts) do
    with true <- initialize_params?(rpc.params),
         {:ok, session} <- Sessions.create(identity, sessions(opts)) do
      result = %{
        "protocolVersion" => @version,
        "capabilities" => %{"tools" => %{}, "resources" => %{}},
        "serverInfo" => %{"name" => "ai-control", "version" => "0.1.0"}
      }

      {:reply, 200, RPC.result(rpc.id, result), [{"mcp-session-id", session}]}
    else
      false -> invalid_params(rpc)
      {:error, :session_capacity} -> reply(429, RPC.error(rpc.id, -32_000, :session_capacity))
    end
  end

  defp dispatch(_, %{method: "initialize"} = rpc, _, _), do: invalid_params(rpc)
  defp dispatch(_, _, nil, _), do: reply(400, RPC.transport(:session_required))

  defp dispatch(identity, rpc, session, opts) do
    case Sessions.fetch(session, identity, sessions(opts)) do
      {:ok, state} -> operation(identity, rpc, session, state, opts)
      {:error, code} -> reply(404, RPC.transport(code))
    end
  end

  defp operation(
         identity,
         %{method: "notifications/initialized", notification?: true} = rpc,
         session,
         _,
         opts
       ) do
    if empty_params?(rpc.params) do
      {:ok, _} = Sessions.ready(session, identity, sessions(opts))
      accepted()
    else
      reply(400, RPC.transport(:invalid_params))
    end
  end

  # Cancellation is optional. The bounded executor cannot safely undo a dispatched effect.
  defp operation(_, %{method: "notifications/cancelled", notification?: true}, _, _, _),
    do: accepted()

  defp operation(_, %{notification?: true}, _, _, _),
    do: reply(400, RPC.transport(:method_not_found))

  defp operation(_, %{method: "ping"} = rpc, _, _, _) do
    if empty_params?(rpc.params), do: success(rpc, %{}), else: invalid_params(rpc)
  end

  defp operation(_, rpc, _, %{ready?: false}, _),
    do: reply(200, RPC.error(rpc.id, -32_000, :not_initialized))

  defp operation(identity, %{method: "tools/list"} = rpc, _, _, _) do
    with true <- empty_params?(rpc.params),
         {:ok, catalog} <- Tools.catalog(identity) do
      tools =
        Enum.map(catalog.tools, fn tool ->
          %{
            "name" => tool["name"],
            "description" => @descriptions[tool["name"]],
            "inputSchema" => tool["parameters"]
          }
        end)

      success(rpc, %{"tools" => tools})
    else
      false -> invalid_params(rpc)
      {:error, code} -> failure(rpc, code)
    end
  end

  defp operation(identity, %{method: "tools/call"} = rpc, session, _, opts) do
    params = rpc.params

    if keys?(params, ~w(name arguments _meta)) && is_binary(params["name"]) &&
         is_map(Map.get(params, "arguments", %{})) do
      execute(
        identity,
        rpc,
        session,
        %{"tool" => params["name"], "arguments" => Map.get(params, "arguments", %{})},
        opts
      )
    else
      invalid_params(rpc)
    end
  end

  defp operation(identity, %{method: "resources/list"} = rpc, session, _, _) do
    with true <- keys?(rpc.params, ~w(cursor _meta)),
         {:ok, catalog} <- Tools.catalog(identity),
         {:ok, after_uri} <- cursor(rpc.params["cursor"], session, catalog.policy_checksum) do
      remaining = Enum.drop_while(catalog.resources, &(&1.uri <= after_uri))
      page = Enum.take(remaining, 100)
      result = %{"resources" => Enum.map(page, &resource/1)}

      result =
        if length(remaining) > 100 do
          token =
            Phoenix.Token.sign(
              AiControlWeb.Endpoint,
              "mcp.resources.v1",
              {session, catalog.policy_checksum, List.last(page).uri}
            )

          Map.put(result, "nextCursor", token)
        else
          result
        end

      success(rpc, result)
    else
      false -> invalid_params(rpc)
      {:error, code} -> failure(rpc, code)
    end
  end

  defp operation(identity, %{method: "resources/read"} = rpc, session, _, opts) do
    with true <- keys?(rpc.params, ~w(uri _meta)) && is_binary(rpc.params["uri"]),
         {:ok, catalog} <- Tools.catalog(identity),
         resource when not is_nil(resource) <-
           Enum.find(catalog.resources, &(&1.uri == rpc.params["uri"])) do
      params = %{"tool" => "file.read", "arguments" => %{"path" => resource.path}}

      case Tools.execute(identity, params, execution_opts(opts, session, rpc.id)) do
        {:ok, data} ->
          success(rpc, %{
            "contents" => [
              %{
                "uri" => resource.uri,
                "mimeType" => "text/plain",
                "text" => data.result["content"]
              }
            ]
          })

        {:error, {code, evidence}} when is_map(evidence) ->
          failure(rpc, code, evidence)

        {:error, {code, _}} ->
          failure(rpc, code)

        {:error, code} ->
          failure(rpc, code)
      end
    else
      false -> invalid_params(rpc)
      nil -> reply(200, RPC.error(rpc.id, -32_002, :resource_not_found))
      {:error, code} -> failure(rpc, code)
    end
  end

  defp operation(_, %{method: "resources/templates/list"} = rpc, _, _, _) do
    if empty_params?(rpc.params),
      do: success(rpc, %{"resourceTemplates" => []}),
      else: invalid_params(rpc)
  end

  defp operation(_, rpc, _, _, _), do: reply(200, RPC.error(rpc.id, -32_601, :method_not_found))

  defp execute(identity, rpc, session, params, opts) do
    case Tools.execute(identity, params, execution_opts(opts, session, rpc.id)) do
      {:ok, data} ->
        success(rpc, %{
          "isError" => false,
          "structuredContent" => data.result,
          "content" => [%{"type" => "text", "text" => Jason.encode!(data.result)}]
        })

      {:error, :tool_not_allowed} ->
        reply(200, RPC.error(rpc.id, -32_602, :tool_not_allowed))

      {:error, {code, evidence}} when is_map(evidence) ->
        success(rpc, RPC.tool_error(code, safe_evidence(evidence)))

      {:error, {code, _}} ->
        success(rpc, RPC.tool_error(code))

      {:error, code} ->
        success(rpc, RPC.tool_error(code))
    end
  end

  defp execution_opts(opts, session, id),
    do:
      Keyword.put(
        Keyword.take(opts, [:request_id, :ingress_checked?, :run_context]),
        :idempotency_key,
        idempotency_key(session, id)
      )

  defp cursor(nil, _, _), do: {:ok, ""}

  defp cursor(value, session, checksum) when is_binary(value) and byte_size(value) <= 4_096 do
    case Phoenix.Token.verify(AiControlWeb.Endpoint, "mcp.resources.v1", value, max_age: 1_800) do
      {:ok, {^session, ^checksum, uri}} when is_binary(uri) -> {:ok, uri}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp cursor(_, _, _), do: {:error, :invalid_cursor}

  defp resource(value),
    do: %{"uri" => value.uri, "name" => value.path, "mimeType" => "text/plain"}

  defp initialize_params?(params) do
    keys?(params, ~w(protocolVersion capabilities clientInfo _meta)) &&
      is_binary(params["protocolVersion"]) && is_map(params["capabilities"]) &&
      is_map(params["clientInfo"]) && is_binary(params["clientInfo"]["name"]) &&
      is_binary(params["clientInfo"]["version"])
  end

  defp empty_params?(params), do: keys?(params, ~w(_meta))
  defp keys?(params, keys), do: Enum.all?(Map.keys(params), &(&1 in keys))
  defp sessions(opts), do: Keyword.get(opts, :sessions, Sessions)

  defp safe_evidence(data),
    do:
      Map.new(Map.take(data, [:execution_id, :execution_status]), fn {k, v} ->
        {Atom.to_string(k), v}
      end)

  defp failure(rpc, code, data \\ %{}),
    do: reply(200, RPC.error(rpc.id, -32_000, code, safe_evidence(data)))

  defp invalid_params(%{notification?: true}), do: reply(400, RPC.transport(:invalid_params))
  defp invalid_params(rpc), do: reply(200, RPC.error(rpc.id, -32_602, :invalid_params))
  defp success(rpc, result), do: reply(200, RPC.result(rpc.id, result))
  defp accepted, do: {:reply, 202, nil, []}
  defp reply(status, body), do: {:reply, status, body, []}
end
