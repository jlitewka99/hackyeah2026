defmodule AiControl.TestStreamHTTPPlug do
  @moduledoc false
  import AiControl.GatewayFixtures
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, owner) do
    case conn.request_path do
      "/models" ->
        Req.Test.json(conn, %{data: [%{id: "deepseek-flash"}]})

      _ ->
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        {:ok, conn} = chunk(conn, "data: " <> stream_chunk(%{"role" => "assistant"}) <> "\n\n")
        send(owner, {:upstream_started, self()})
        hold(conn)
    end
  end

  defp hold(conn) do
    receive do
      {:release, body} ->
        case chunk(conn, body) do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end
    after
      10 ->
        case chunk(conn, ": upstream heartbeat\n\n") do
          {:ok, next} -> hold(next)
          {:error, _} -> conn
        end
    end
  end
end
