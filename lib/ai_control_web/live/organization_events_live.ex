defmodule AiControlWeb.OrganizationEventsLive do
  use AiControlWeb, :live_view

  alias AiControl.Audit
  alias AiControl.Audit.Filters
  alias AiControlWeb.{ReportingHTML, ReportingLive}

  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(page_title: "Events", filters: nil, next_cursor: nil, report_error: nil)
     |> stream(:events, [])
     |> ReportingLive.install(&refresh/1)}
  end

  def handle_params(params, _, socket) do
    case Filters.parse(params) do
      {:ok, filters} ->
        {:noreply,
         socket
         |> assign(filters: filters, form: to_form(Ecto.Changeset.change(filters), as: :filters))
         |> refresh()}

      {:error, changeset} ->
        {:ok, defaults} = Filters.parse()

        {:noreply,
         socket |> assign(filters: defaults, form: to_form(changeset, as: :filters)) |> refresh()}
    end
  end

  def handle_event("filter", %{"filters" => params}, socket) do
    case Filters.parse(params) do
      {:ok, filters} ->
        {:noreply,
         push_patch(socket,
           to:
             ~p"/organizations/#{socket.assigns.current_scope.organization.id}/events?#{Filters.params(filters)}"
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :filters))}
    end
  end

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(%{assigns: %{filters: nil}} = socket), do: socket

  defp refresh(socket) do
    {:ok, filters} =
      Filters.parse(
        Map.put(Filters.params(socket.assigns.filters), "cursor", socket.assigns.filters.cursor)
      )

    case Audit.page_events(socket.assigns.current_scope, filters) do
      {:ok, page} ->
        socket
        |> assign(filters: filters, next_cursor: page.next, report_error: nil)
        |> stream(:events, page.events, reset: true)

      {:error, _} ->
        assign(socket, :report_error, "Events could not be loaded. Try again shortly.")
    end
  end
end
