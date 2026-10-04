defmodule AiControl.MCP.RPC do
  @moduledoc "Closed JSON-RPC envelope validation and content-free public errors."
  @methods ~w(initialize ping tools/list tools/call resources/list resources/read resources/templates/list notifications/initialized notifications/cancelled)

  def validate(%{"jsonrpc" => "2.0", "method" => method} = message) when is_binary(method) do
    id = Map.get(message, "id")
    notification? = !Map.has_key?(message, "id")
    params = Map.get(message, "params", %{})

    if (notification? || valid_id?(id)) && is_map(params) &&
         Enum.all?(Map.keys(message), &(&1 in ~w(jsonrpc method id params))) do
      {:ok, %{id: id, method: method, params: params, notification?: notification?}}
    else
      {:error, error(nil, -32_600, :invalid_request)}
    end
  end

  def validate(_), do: {:error, error(nil, -32_600, :invalid_request)}

  def valid_id?(id) when is_integer(id),
    do: id >= -9_007_199_254_740_991 && id <= 9_007_199_254_740_991

  def valid_id?(id) when is_binary(id), do: String.valid?(id) && byte_size(id) <= 256
  def valid_id?(_), do: false
  def method_label(method), do: if(method in @methods, do: method, else: "unknown")

  def result(id, value), do: %{"jsonrpc" => "2.0", "id" => id, "result" => value}

  def error(id, number, code, data \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => number,
        "message" => message(code),
        "data" => Map.put(data, "code", Atom.to_string(code))
      }
    }
  end

  def transport(code),
    do: %{"error" => %{"code" => Atom.to_string(code), "message" => message(code)}}

  def tool_error(code, data \\ %{}) do
    %{
      "isError" => true,
      "content" => [%{"type" => "text", "text" => message(code)}],
      "_meta" => Map.put(data, "code", Atom.to_string(code))
    }
  end

  def message(:invalid_request), do: "Unsupported or invalid MCP request."
  def message(:parse_error), do: "Invalid JSON."
  def message(:invalid_params), do: "Unsupported or invalid MCP parameters."
  def message(:method_not_found), do: "MCP method is not supported."
  def message(:session_required), do: "An MCP session is required."
  def message(:session_not_found), do: "MCP session is unavailable. Initialize a new session."
  def message(:not_initialized), do: "Complete MCP initialization before this operation."
  def message(:session_capacity), do: "MCP session capacity is exhausted."
  def message(:unsupported_version), do: "MCP protocol version is not supported."
  def message(:invalid_origin), do: "Request origin is not allowed."
  def message(:input_too_large), do: "MCP request exceeds the size limit."
  def message(:response_too_large), do: "MCP response exceeds the size limit."
  def message(:not_acceptable), do: "Accept must include application/json and text/event-stream."
  def message(:unsupported_media_type), do: "Content-Type must be application/json."
  def message(:rate_limited), do: "Gateway is busy. Try again later."
  def message(:tool_budget_exceeded), do: "Tool context budget exceeded."

  def message(:tool_execution_exists),
    do: "This request has already been processed; its result cannot be replayed."

  def message(:idempotency_conflict),
    do: "This request identifier has already been used for another operation."

  def message(:invalid_cursor),
    do: "Resource cursor is invalid. List resources again without a cursor."

  def message(:resource_not_found), do: "Resource is unavailable or not allowed."
  def message(:tool_not_allowed), do: "Tool is unavailable or not allowed."

  def message(code)
      when code in ~w(forbidden policy_blocked redaction_unavailable tool_resource_not_allowed tool_resource_not_found)a,
      do: "Request is not allowed."

  def message(code) when code in ~w(invalid_tool_request invalid_tool_arguments invalid_request)a,
    do: "Unsupported or invalid tool request."

  def message(_), do: "Gateway is temporarily unavailable."
end
