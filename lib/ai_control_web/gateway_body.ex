defmodule AiControlWeb.GatewayBody do
  @moduledoc "Authenticate and bound JSON before the general endpoint parser buffers a chat body."
  import Plug.Conn

  alias AiControl.Audit
  alias AiControl.Gateway.{Config, Limiter}
  alias AiControlWeb.{ApiKeyAuth, GatewayError}

  def init(opts), do: opts

  def call(%{method: method, request_path: path} = conn, _)
      when method in ["POST", "PATCH", "DELETE"] do
    if path in [
         "/v1/chat/completions",
         "/v1/tool_calls",
         "/v1/knowledge/search",
         "/v1/memory",
         "/v1/runs"
       ] or
         String.starts_with?(path, "/v1/memory/") or String.starts_with?(path, "/v1/runs/") do
      authenticate(conn)
    else
      conn
    end
  end

  def call(conn, _), do: conn

  defp authenticate(conn) do
    conn = ApiKeyAuth.call(conn, [])

    if conn.halted do
      conn
    else
      case Limiter.check(conn.assigns.api_principal) do
        :ok -> conn |> assign(:gateway_ingress_checked, true) |> parse()
        {:error, {code, retry}} -> reject(conn, code, retry)
      end
    end
  end

  defp parse(conn) do
    with [type] <- get_req_header(conn, "content-type"),
         true <-
           type |> String.split(";") |> hd() |> String.trim() |> String.downcase() ==
             "application/json",
         {:ok, body, conn} <- read(conn, [], 0),
         {:ok, params} when is_map(params) <- Jason.decode(body, strings: :copy) do
      %{conn | body_params: params}
    else
      {:error, code, conn} -> reject(conn, code)
      _ -> reject(conn, :invalid_request)
    end
  end

  defp read(conn, chunks, size) do
    case read_body(conn,
           length: min(65_536, input_limit(conn) + 1),
           read_length: 65_536,
           read_timeout: 2_000
         ) do
      {status, chunk, conn} when status in [:ok, :more] ->
        size = size + byte_size(chunk)

        cond do
          size > input_limit(conn) -> {:error, :input_too_large, conn}
          status == :more -> read(conn, [chunk | chunks], size)
          true -> {:ok, [chunk | chunks] |> Enum.reverse() |> IO.iodata_to_binary(), conn}
        end

      _ ->
        {:error, :invalid_request, conn}
    end
  end

  defp input_limit(%{request_path: "/v1/runs" <> _}), do: 4096
  defp input_limit(%{request_path: "/v1/tool_calls"}), do: 65_536
  defp input_limit(%{request_path: "/v1/knowledge/search"}), do: 4096
  defp input_limit(%{request_path: "/v1/memory" <> _}), do: 65_536
  defp input_limit(_), do: Config.get(:input_bytes)

  defp knowledge_operation(%{request_path: "/v1/knowledge/search"}), do: "knowledge.search"
  defp knowledge_operation(%{method: "POST"}), do: "knowledge.created"
  defp knowledge_operation(%{method: "PATCH"}), do: "knowledge.updated"
  defp knowledge_operation(%{method: "DELETE"}), do: "knowledge.deleted"

  defp reject(conn, code, retry \\ nil) do
    result =
      cond do
        String.starts_with?(conn.request_path, "/v1/memory") or
            conn.request_path == "/v1/knowledge/search" ->
          Audit.record_knowledge(
            conn.assigns.api_principal,
            conn.assigns.request_id,
            knowledge_operation(conn),
            Atom.to_string(code),
            nil,
            []
          )

        conn.request_path == "/v1/tool_calls" ->
          Audit.record_tool(
            conn.assigns.api_principal,
            conn.assigns.request_id,
            "tool.rejected",
            Atom.to_string(code),
            0,
            nil,
            nil
          )

        true ->
          Audit.record_gateway(
            conn.assigns.api_principal,
            conn.assigns.request_id,
            Atom.to_string(code),
            0,
            nil,
            :input,
            nil,
            %{
              operation:
                if(String.starts_with?(conn.request_path, "/v1/runs"), do: "runs", else: "chat"),
              timings: %{}
            }
          )
      end

    code = if match?({:ok, _}, result), do: code, else: :audit_unavailable

    error =
      if retry && code != :audit_unavailable, do: {:error, {code, retry}}, else: {:error, code}

    conn |> GatewayError.respond(error) |> halt()
  end
end
