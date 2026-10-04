defmodule AiControlWeb.GatewayIngress do
  @moduledoc "Bound unauthenticated gateway attempts before parsing or API-key lookup."
  import Plug.Conn

  alias AiControl.Gateway.Limiter
  alias AiControlWeb.GatewayError

  def init(opts), do: opts

  def call(%{request_path: path} = conn, _)
      when path in [
             "/v1/models",
             "/v1/chat/completions",
             "/v1/tool_calls",
             "/v1/knowledge/search",
             "/v1/memory"
           ] do
    case Limiter.check_ip(conn.remote_ip) do
      :ok -> conn
      error -> conn |> GatewayError.respond(error) |> halt()
    end
  end

  def call(%{request_path: "/v1/memory/" <> _} = conn, _),
    do: call(%{conn | request_path: "/v1/memory"}, []) |> restore_path(conn.request_path)

  def call(conn, _), do: conn
  defp restore_path(conn, path), do: %{conn | request_path: path}
end
