defmodule AiControlWeb.MCPTransport do
  @moduledoc "Authenticate and bound MCP traffic before the endpoint's general body parser."
  import Plug.Conn

  alias AiControl.Gateway.Limiter
  alias AiControl.MCP
  alias AiControl.MCP.{Config, RPC, Sessions}
  alias AiControlWeb.ApiKeyAuth

  def init(opts), do: opts

  def call(%{request_path: "/mcp"} = conn, _) do
    started = System.monotonic_time()

    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> register_before_send(&measure(&1, started))

    with :ok <- Limiter.check_ip(conn.remote_ip),
         :ok <- origin(conn) do
      authenticate(conn)
    else
      {:error, {code, retry}} -> reject(conn, 429, code, retry)
      {:error, code} -> reject(conn, 403, code)
    end
  rescue
    _ -> reject(conn, 503, :gateway_unavailable)
  catch
    :exit, _ -> reject(conn, 503, :gateway_unavailable)
  end

  def call(conn, _), do: conn

  defp measure(conn, started) do
    method = if is_map(conn.body_params), do: Map.get(conn.body_params, "method")

    :telemetry.execute(
      [:ai_control, :mcp, :request],
      %{
        duration_us:
          System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
      },
      %{method: RPC.method_label(method), status: conn.status}
    )

    conn
  end

  defp authenticate(conn) do
    conn = ApiKeyAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case Limiter.check(conn.assigns.api_principal) do
        :ok -> conn |> assign(:gateway_ingress_checked, true) |> headers()
        {:error, {code, retry}} -> reject(conn, 429, code, retry)
      end
    end
  end

  defp headers(conn) do
    with :ok <- protocol(conn),
         {:ok, session} <- session_header(conn),
         :ok <- existing_session(session, conn.assigns.api_principal) do
      conn |> assign(:mcp_session, session) |> method()
    else
      {:error, :session_not_found = code} -> reject(conn, 404, code)
      {:error, code} -> reject(conn, 400, code)
    end
  end

  defp method(%{method: "POST"} = conn) do
    with :ok <- media(conn),
         :ok <- accept(conn),
         {:ok, body, conn} <- read(conn, [], 0) do
      case Jason.decode(body, strings: :copy) do
        {:ok, message} when is_map(message) -> %{conn | body_params: message}
        {:ok, _} -> conn |> respond(400, RPC.error(nil, -32_600, :invalid_request)) |> halt()
        _ -> conn |> respond(400, RPC.error(nil, -32_700, :parse_error)) |> halt()
      end
    else
      {:error, :input_too_large = code, conn} -> reject(conn, 413, code)
      {:error, code, conn} -> reject(conn, 400, code)
      {:error, :unsupported_media_type = code} -> reject(conn, 415, code)
      {:error, code} -> reject(conn, 406, code)
    end
  end

  defp method(%{method: "DELETE"} = conn) do
    case conn.assigns.mcp_session do
      nil ->
        reject(conn, 400, :session_required)

      id ->
        case Sessions.delete(id, conn.assigns.api_principal) do
          :ok -> conn |> send_resp(204, "") |> halt()
          {:error, code} -> reject(conn, 404, code)
        end
    end
  end

  defp method(conn) do
    case conn.assigns.mcp_session do
      nil ->
        unsupported_method(conn)

      id ->
        case Sessions.fetch(id, conn.assigns.api_principal) do
          {:ok, _} -> unsupported_method(conn)
          {:error, code} -> reject(conn, 404, code)
        end
    end
  end

  defp unsupported_method(conn),
    do: conn |> put_resp_header("allow", "POST, DELETE") |> reject(405, :method_not_found)

  defp origin(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [value] ->
        if Config.origin?(value) && value in [Config.public_origin() | Config.allowed_origins()],
          do: :ok,
          else: {:error, :invalid_origin}

      _ ->
        {:error, :invalid_origin}
    end
  end

  defp protocol(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> :ok
      [value] -> if value == MCP.version(), do: :ok, else: {:error, :unsupported_version}
      _ -> {:error, :unsupported_version}
    end
  end

  defp session_header(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [] -> {:ok, nil}
      [value] when byte_size(value) in 1..64 -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end

  defp existing_session(nil, _), do: :ok

  defp existing_session(id, identity) do
    case Sessions.fetch(id, identity) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp media(conn) do
    case get_req_header(conn, "content-type") do
      [type] ->
        if type |> String.split(";") |> hd() |> String.trim() |> String.downcase() ==
             "application/json", do: :ok, else: {:error, :unsupported_media_type}

      _ ->
        {:error, :unsupported_media_type}
    end
  end

  defp accept(conn) do
    types =
      conn
      |> get_req_header("accept")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.downcase(String.trim(&1)))
      |> Enum.reject(&Regex.match?(~r/;\s*q=0(?:\.0*)?(?:;|$)/, &1))
      |> Enum.map(&(&1 |> String.split(";") |> hd() |> String.trim()))

    if "application/json" in types && "text/event-stream" in types,
      do: :ok,
      else: {:error, :not_acceptable}
  end

  defp read(conn, chunks, size) do
    case read_body(conn, length: 65_536, read_length: 65_536, read_timeout: 2_000) do
      {status, chunk, conn} when status in [:ok, :more] ->
        size = size + byte_size(chunk)

        cond do
          size > Config.input_bytes() -> {:error, :input_too_large, conn}
          status == :more -> read(conn, [chunk | chunks], size)
          true -> {:ok, [chunk | chunks] |> Enum.reverse() |> IO.iodata_to_binary(), conn}
        end

      _ ->
        {:error, :invalid_request, conn}
    end
  end

  def respond(conn, status, body) do
    encoded = Jason.encode!(body)

    {status, encoded} =
      if byte_size(encoded) > Config.response_bytes() do
        id = if is_map(body), do: Map.get(body, "id")
        {500, Jason.encode!(RPC.error(id, -32_603, :response_too_large))}
      else
        {status, encoded}
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, encoded)
  end

  defp reject(conn, status, code, retry \\ nil) do
    conn =
      if retry, do: put_resp_header(conn, "retry-after", Integer.to_string(retry)), else: conn

    conn |> respond(status, RPC.transport(code)) |> halt()
  end
end
