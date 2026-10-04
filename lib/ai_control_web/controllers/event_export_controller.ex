defmodule AiControlWeb.EventExportController do
  use AiControlWeb, :controller

  alias AiControl.Audit.{Export, Filters}

  def index(conn, params) do
    with {:ok, scope} <- Export.authorize(conn.assigns.current_scope),
         {:ok, filters} <- Filters.parse(freeze_range(Map.delete(params, "organization_id"))) do
      conn =
        conn
        |> put_resp_content_type("application/x-ndjson")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="audit-#{scope.organization.id}.jsonl")
        )
        |> put_resp_header("cache-control", "no-store")
        |> send_chunked(200)

      case Export.run(scope, filters, conn, &chunk/2) do
        {:ok, {conn, _count}} -> conn
        {:error, _} -> conn
      end
    else
      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> text("Audit export access is required.")

      _ ->
        conn
        |> put_status(:bad_request)
        |> text("Choose valid audit filters and a UTC time range.")
    end
  end

  defp freeze_range(%{"from" => first, "to" => last} = params) when first != "" and last != "",
    do: Map.put(params, "range", "custom")

  defp freeze_range(params), do: params
end
