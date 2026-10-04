defmodule AiControlWeb.GatewayIngress do
  @moduledoc "Bound unauthenticated gateway attempts before parsing or API-key lookup."
  import Plug.Conn

  alias AiControl.Gateway.Limiter
  alias AiControlWeb.GatewayError

  def init(opts), do: opts

  def call(%{request_path: path} = conn, _)
      when path in ["/v1/models", "/v1/chat/completions", "/v1/tool_calls", "/v1/runs"] or
             (is_binary(path) and binary_part(path, 0, min(byte_size(path), 9)) == "/v1/runs/") do
    case Limiter.check_ip(conn.remote_ip) do
      :ok -> conn
      error -> conn |> GatewayError.respond(error) |> halt()
    end
  end

  def call(conn, _), do: conn
end
