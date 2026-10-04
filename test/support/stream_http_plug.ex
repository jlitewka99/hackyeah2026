defmodule AiControl.TestStreamHTTPPlug do
  @moduledoc false
  import AiControl.GatewayFixtures
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, owner) do
    case conn.request_path do
      "/api/tags" ->
        Req.Test.json(conn, %{models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]})

      "/api/version" ->
        Req.Test.json(conn, %{version: "0.35.1"})

      _ ->
        {:ok, body, conn} = read_body(conn)

        if Jason.decode!(body)["_debug_render_only"] do
          Req.Test.json(conn, %{_debug_info: %{rendered_template: "safe input"}})
        else
          conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
          {:ok, conn} = chunk(conn, "data: " <> stream_chunk(%{"role" => "assistant"}) <> "\n\n")
          send(owner, {:upstream_started, self()})
          hold(conn)
        end
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
