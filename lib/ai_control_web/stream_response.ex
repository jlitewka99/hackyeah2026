defmodule AiControlWeb.StreamResponse do
  @moduledoc "Sequential SSE socket writes with heartbeats and supervised cancellation."
  import Plug.Conn

  alias AiControl.Gateway.{Config, Stream, StreamEncoder}
  alias AiControlWeb.GatewayError

  def send(conn, pid, include_usage?) do
    ref = Process.monitor(pid)

    try do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      case chunk(conn, ": keepalive\n\n") do
        {:ok, conn} ->
          Stream.begin(pid)
          await(conn, pid, ref, include_usage?)

        {:error, _} ->
          conn
      end
    after
      Process.demonitor(ref, [:flush])
      cancel(pid)
    end
  end

  defp await(conn, pid, ref, include_usage?) do
    receive do
      {^pid, {:ready, response}} -> deliver(conn, pid, response, include_usage?)
      {^pid, {:error, {code, _}}} -> error(conn, code)
      {^pid, {:error, code}} -> error(conn, code)
      {:DOWN, ^ref, :process, ^pid, _} -> error(conn, :upstream_unavailable)
    after
      Config.get(:stream_heartbeat_ms) ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, next} -> await(next, pid, ref, include_usage?)
          {:error, _} -> conn
        end
    end
  end

  defp deliver(conn, pid, response, include_usage?) do
    result =
      response
      |> StreamEncoder.frames(include_usage?)
      |> Enum.reduce_while({:ok, conn, %{"sent_bytes" => 0, "sent_chunks" => 0}}, fn frame,
                                                                                     {:ok, conn,
                                                                                      counts} ->
        case chunk(conn, frame) do
          {:ok, next} ->
            :ok = GenServer.call(pid, {:sent, byte_size(frame)})

            counts =
              counts
              |> Map.update!("sent_bytes", &(&1 + byte_size(frame)))
              |> Map.update!("sent_chunks", &(&1 + 1))

            {:cont, {:ok, next, counts}}

          {:error, _} ->
            {:halt, {:error, conn}}
        end
      end)

    case result do
      {:ok, conn, counts} ->
        case Stream.complete(pid, counts) do
          :ok -> finish(conn, pid)
          {:error, code} -> error(conn, code)
        end

      {:error, conn} ->
        conn
    end
  end

  defp finish(conn, pid) do
    case chunk(conn, "data: [DONE]\n\n") do
      {:ok, next} ->
        :ok = Stream.delivered(pid)
        next

      {:error, _} ->
        conn
    end
  end

  defp error(conn, code),
    do:
      write(
        conn,
        "event: error\ndata: " <>
          Jason.encode!(GatewayError.payload(code, conn.assigns[:request_id])) <> "\n\n"
      )

  defp write(conn, frame) do
    case chunk(conn, frame) do
      {:ok, next} -> next
      {:error, _} -> conn
    end
  end

  defp cancel(pid) do
    Stream.cancel(pid)
  catch
    :exit, _ -> :ok
  end
end
