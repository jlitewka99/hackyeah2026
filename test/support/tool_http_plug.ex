defmodule AiControl.TestToolHTTPPlug do
  @moduledoc false
  import Plug.Conn

  def init(owner), do: owner

  def call(conn, owner) do
    send(owner, {:tool_http_request, conn.request_path, get_req_header(conn, "host")})

    case conn.request_path do
      "/ok" ->
        send_resp(conn, 200, "Synthetic HTTP report")

      "/redirect" ->
        conn |> put_resp_header("location", "/target") |> send_resp(302, "sensitive-upstream")

      "/large" ->
        send_resp(conn, 200, String.duplicate("x", 65_537))

      "/invalid" ->
        send_resp(conn, 200, <<255>>)

      _ ->
        send_resp(conn, 500, "sensitive-upstream")
    end
  end
end
