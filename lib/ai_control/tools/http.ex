defmodule AiControl.Tools.HTTP do
  @moduledoc "Req transport to an operator-pinned IP, retaining Host and TLS hostname verification."
  @max_bytes 65_536

  def get(%{uri: uri, ip: ip}) do
    address = ip |> :inet.ntoa() |> to_string()
    pinned = URI.to_string(%{uri | host: address})
    host = host_header(uri)

    case Req.get(pinned,
           headers: [{"host", host}],
           finch: [
             conn_opts: [
               hostname: uri.host,
               transport_opts: [timeout: 2_000, inet6: tuple_size(ip) == 8]
             ],
             protocols: [:http1],
             pool_timeout: 2_000,
             receive_timeout: 2_000,
             request_timeout: 3_000
           ],
           retry: false,
           redirect: false,
           raw: true,
           compressed: false,
           into: &collect/2
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        if is_binary(body) && String.valid?(body),
          do: {:ok, %{"status" => status, "body" => body}},
          else: {:error, :tool_upstream_unavailable}

      {:ok, %{status: status}} when status in 300..399 ->
        {:error, :tool_redirect_blocked}

      _ ->
        {:error, :tool_upstream_unavailable}
    end
  rescue
    _ -> {:error, :tool_upstream_unavailable}
  catch
    :exit, _ -> {:error, :tool_upstream_unavailable}
  end

  defp host_header(uri) do
    host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host

    default =
      (uri.scheme == "http" && uri.port == 80) || (uri.scheme == "https" && uri.port == 443)

    if default, do: host, else: "#{host}:#{uri.port}"
  end

  defp collect({:data, data}, {request, response}) do
    body = (response.body || "") <> data

    if byte_size(body) <= @max_bytes,
      do: {:cont, {request, %{response | body: body}}},
      else: {:halt, {request, %{response | status: 413, body: ""}}}
  end
end
