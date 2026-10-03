defmodule AiControlWeb.RequestLog do
  @moduledoc "Safe request telemetry. Never formats connections, parameters, paths or exceptions."
  use GenServer

  alias AiControl.Security.Validation

  require Logger

  @events [[:phoenix, :router_dispatch, :stop], [:phoenix, :error_rendered]]
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :telemetry.detach(__MODULE__)
    :ok = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.log/4, nil)
    {:ok, nil}
  end

  @impl true
  def terminate(_, _), do: :telemetry.detach(__MODULE__)

  def level(_conn), do: false

  def log(event, measurements, metadata, _) do
    conn = metadata.conn

    status = metadata[:status] || conn.status || 500
    duration_us = System.convert_time_unit(measurements[:duration] || 0, :native, :microsecond)
    {route, code} = route_and_code(event, metadata, status)

    Logger.log(
      if(status >= 500, do: :error, else: :info),
      "http #{method(conn)} #{route} status=#{status} duration_us=#{duration_us} code=#{code}",
      request_id: request_id(conn)
    )
  end

  defp method(%{method: method}) when method in ~w(GET POST PUT PATCH DELETE HEAD OPTIONS),
    do: method

  defp method(_), do: "OTHER"

  defp request_id(conn) do
    id = Map.get(conn.assigns, :request_id)
    if Validation.uuid?(id), do: id
  end

  defp route_and_code([:phoenix, :error_rendered], _, status), do: {"error", error_code(status)}
  defp route_and_code(_, metadata, _), do: {metadata[:route] || "unmatched", "request_completed"}

  defp error_code(status) when status >= 500, do: "internal_error"
  defp error_code(400), do: "invalid_request"
  defp error_code(403), do: "forbidden"
  defp error_code(404), do: "not_found"
  defp error_code(413), do: "request_too_large"
  defp error_code(_), do: "request_rejected"
end
