defmodule AiControlWeb.KnowledgeController do
  use AiControlWeb, :controller

  alias AiControl.Knowledge
  alias AiControlWeb.GatewayError

  def index(conn, _),
    do:
      respond(
        conn,
        Knowledge.list(
          identity(conn),
          conn.query_params
          |> Map.take(~w(agent_id))
          |> Map.put("page", page(conn))
          |> Map.merge(sources(conn)),
          opts(conn)
        )
      )

  def show(conn, %{"id" => id}), do: respond(conn, Knowledge.get(identity(conn), id, opts(conn)))

  def search(conn, _),
    do: respond(conn, Knowledge.search(identity(conn), conn.body_params, opts(conn)))

  def create(conn, _),
    do:
      respond(
        conn,
        Knowledge.create(
          identity(conn),
          conn.body_params,
          Keyword.put(opts(conn), :origin, "api")
        ),
        201
      )

  def update(conn, %{"id" => id}),
    do: respond(conn, Knowledge.update(identity(conn), id, conn.body_params, opts(conn)))

  def delete(conn, %{"id" => id}),
    do:
      respond(
        conn,
        Knowledge.delete(identity(conn), id, conn.body_params["revision"], opts(conn))
      )

  defp page(conn) do
    case Integer.parse(conn.query_params["page"] || "1") do
      {page, ""} -> page
      _ -> 0
    end
  end

  defp identity(conn), do: conn.assigns[:api_principal] || conn.assigns.current_scope

  defp opts(conn),
    do: [
      request_id: conn.assigns.request_id,
      ingress_checked?: conn.assigns[:gateway_ingress_checked] == true,
      kind: if(String.starts_with?(conn.request_path, "/v1/memory"), do: "memory")
    ]

  defp sources(%{request_path: "/v1/memory"}), do: %{"sources" => ["memory"]}
  defp sources(_), do: %{}
  defp respond(conn, result, status \\ 200)

  defp respond(conn, {:ok, data}, status),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(status)
      |> json(%{data: data})

  defp respond(conn, error, _status), do: GatewayError.respond(conn, error)
end
