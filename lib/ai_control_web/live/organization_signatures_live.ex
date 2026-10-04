defmodule AiControlWeb.OrganizationSignaturesLive do
  use AiControlWeb, :live_view

  alias AiControl.Audit.Filters
  alias AiControl.Background
  alias AiControl.Background.Request
  alias AiControl.Dashboard
  alias AiControl.Guards.Feeds
  alias AiControlWeb.{BackgroundHTML, ReportingHTML, ReportingLive}

  def mount(_, _, socket),
    do:
      {:ok,
       socket
       |> assign(:page_title, "Signatures")
       |> assign(:feed_form, to_form(Request.changeset(), as: :feed))
       |> ReportingLive.install(&refresh/1)
       |> refresh()}

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  def handle_event("refresh_feed", %{"feed" => attrs}, socket) do
    case Background.enqueue(socket.assigns.current_scope, "guard_refresh", attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Refresh queued. A verified package becomes a candidate; activate it through Policies."
         )
         |> refresh()}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The refresh could not be queued. Check the package and signatures.manage access."
         )}
    end
  end

  def handle_event("cancel_run", %{"id" => id}, socket) do
    _ = Background.cancel(socket.assigns.current_scope, id)
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    report = Dashboard.signatures(socket.assigns.current_scope)
    {:ok, filters} = Filters.parse(%{"guard" => "signatures"})
    activity = Dashboard.activity(socket.assigns.current_scope, filters)

    signatures =
      if ReportingHTML.ok?(report), do: ReportingHTML.value(report).signatures, else: []

    detections =
      if ReportingHTML.ok?(activity), do: ReportingHTML.value(activity).detections, else: []

    {:ok, sets} = Feeds.list(socket.assigns.current_scope)
    {:ok, runs} = Background.list(socket.assigns.current_scope, ["guard_refresh"])

    socket
    |> assign(report: report, activity: activity)
    |> assign(:packages, Feeds.package_ids())
    |> stream(:sets, sets, reset: true)
    |> stream(:runs, runs, reset: true)
    |> stream(:signatures, signatures, reset: true)
    |> stream(:detections, detections, reset: true)
  end
end
