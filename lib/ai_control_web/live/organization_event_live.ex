defmodule AiControlWeb.OrganizationEventLive do
  use AiControlWeb, :live_view

  alias AiControl.Audit
  alias AiControl.Audit.Serializer
  alias AiControlWeb.{ReportingHTML, ReportingLive}

  def mount(params, _, socket),
    do:
      {:ok,
       socket
       |> assign(page_title: "Event details", event_id: params["event_id"])
       |> ReportingLive.install(&refresh/1)
       |> refresh()}

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    with {:ok, event} <- Audit.get_event(socket.assigns.current_scope, socket.assigns.event_id),
         {:ok, events} <- Audit.request_events(socket.assigns.current_scope, event.request_id) do
      socket
      |> assign(event: event, evidence: Jason.encode!(Serializer.event(event), pretty: true))
      |> stream(:chronology, events, reset: true)
    else
      _ ->
        socket
        |> put_flash(:error, "This event is unavailable in your organization.")
        |> redirect(to: ~p"/organizations/#{socket.assigns.current_scope.organization.id}/events")
    end
  end
end
