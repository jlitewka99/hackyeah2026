defmodule AiControlWeb.OrganizationSignaturesLive do
  use AiControlWeb, :live_view

  alias AiControl.Audit.Filters
  alias AiControl.Dashboard
  alias AiControlWeb.{ReportingHTML, ReportingLive}

  def mount(_, _, socket),
    do:
      {:ok,
       socket
       |> assign(:page_title, "Signatures")
       |> ReportingLive.install(&refresh/1)
       |> refresh()}

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    report = Dashboard.signatures(socket.assigns.current_scope)
    {:ok, filters} = Filters.parse(%{"guard" => "signatures"})
    activity = Dashboard.activity(socket.assigns.current_scope, filters)

    signatures =
      if ReportingHTML.ok?(report), do: ReportingHTML.value(report).signatures, else: []

    detections =
      if ReportingHTML.ok?(activity), do: ReportingHTML.value(activity).detections, else: []

    socket
    |> assign(report: report, activity: activity)
    |> stream(:signatures, signatures, reset: true)
    |> stream(:detections, detections, reset: true)
  end
end
