defmodule AiControlWeb.BackgroundDownloadController do
  use AiControlWeb, :controller

  alias AiControl.Background

  def show(conn, %{"run_id" => id}) do
    with {:ok, run} <- Background.artifact(conn.assigns.current_scope, id),
         true <- run.kind != "guard_refresh" do
      conn
      |> put_resp_content_type("application/x-ndjson")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{run.kind}-#{run.id}.jsonl")
      )
      |> put_resp_header("x-artifact-sha256", run.checksum)
      |> send_chunked(200)
      |> send_pages(run.id, -1)
    else
      _ -> conn |> put_status(:not_found) |> text("This artifact is unavailable or has expired.")
    end
  end

  defp send_pages(conn, id, cursor) do
    case Background.chunk_page(conn.assigns.current_scope, id, cursor) do
      {:ok, [chunk]} ->
        case chunk(conn, chunk.data) do
          {:ok, conn} -> send_pages(conn, id, chunk.position)
          _ -> conn
        end

      _ ->
        conn
    end
  end
end
