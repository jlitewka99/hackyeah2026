defmodule AiControl.MCP.Config do
  @moduledoc "Startup-owned MCP transport and bounded session configuration."
  def get, do: Application.get_env(:ai_control, __MODULE__, [])
  def idle_timeout, do: Keyword.get(get(), :idle_timeout_ms, 1_800_000)
  def agent_sessions, do: Keyword.get(get(), :max_agent_sessions, 32)
  def total_sessions, do: Keyword.get(get(), :max_sessions, 1_000)
  def input_bytes, do: 65_536
  def response_bytes, do: 262_144
  def allowed_origins, do: Keyword.get(get(), :allowed_origins, [])

  def validate! do
    limits = [idle_timeout(), agent_sessions(), total_sessions()]
    origins = allowed_origins()

    if !Enum.all?(limits, &(is_integer(&1) && &1 > 0)) || !is_list(origins) ||
         !Enum.all?(origins, &origin?/1),
       do: raise(ArgumentError, "invalid MCP configuration")

    :ok
  end

  def origin?(value) when is_binary(value) do
    uri = URI.parse(value)

    uri.scheme in ~w(http https) && is_binary(uri.host) && uri.host != "" &&
      is_nil(uri.userinfo) && is_nil(uri.query) && is_nil(uri.fragment) &&
      uri.path in [nil, ""] && uri.port in 1..65_535 &&
      !Regex.match?(~r/[\s,*]/, value)
  rescue
    _ -> false
  end

  def origin?(_), do: false

  def public_origin do
    uri = URI.parse(AiControlWeb.Endpoint.url())
    URI.to_string(%{uri | path: nil, query: nil, fragment: nil})
  end

  def endpoint, do: String.trim_trailing(AiControlWeb.Endpoint.url(), "/") <> "/mcp"
end
