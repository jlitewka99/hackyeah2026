defmodule AiControlWeb.OrganizationReportsLive do
  use AiControlWeb, :live_view

  alias AiControl.Background
  alias AiControl.Background.Request
  alias AiControlWeb.{BackgroundHTML, ReportingLive}

  def mount(_, _, socket),
    do:
      {:ok,
       socket
       |> assign(page_title: "Reports", form: to_form(Request.changeset(), as: :report))
       |> ReportingLive.install(&refresh/1)
       |> refresh()}

  def handle_event("generate", %{"report" => params}, socket) do
    attrs = %{
      "filters" => %{"range" => params["range"]},
      "include_budgets" => params["include_budgets"]
    }

    case Background.enqueue(socket.assigns.current_scope, params["kind"], attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Report queued. Download it from history when it finishes.")
         |> refresh()}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The report could not be queued. Check your permissions and try again."
         )}
    end
  end

  def handle_event("cancel_run", %{"id" => id}, socket) do
    _ = Background.cancel(socket.assigns.current_scope, id)
    {:noreply, refresh(socket)}
  end

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    {:ok, runs} =
      Background.list(
        socket.assigns.current_scope,
        ~w(metrics_report audit_export audit_enrichment)
      )

    stream(socket, :runs, runs, reset: true)
  end
end
