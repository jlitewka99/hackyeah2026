defmodule AiControlWeb.ReportingLive do
  @moduledoc "Coalesces content-free notifications; the organization hook refreshes access before each callback."
  import Phoenix.Component
  import Phoenix.LiveView

  def install(socket, refresh) do
    if connected?(socket) do
      id = socket.assigns.current_scope.organization.id
      Phoenix.PubSub.subscribe(AiControl.PubSub, "organizations:#{id}:dashboard")
      Phoenix.PubSub.subscribe(AiControl.PubSub, "organizations:#{id}:policies")
      Phoenix.PubSub.subscribe(AiControl.PubSub, "platform:policies")
      Process.send_after(self(), :reporting_tick, 60_000)
    end

    socket
    |> assign(:reporting_pending?, false)
    |> attach_hook(:reporting_updates, :handle_info, fn
      message, socket when message in [:dashboard_changed, :policies_changed] ->
        if !socket.assigns.reporting_pending?,
          do: Process.send_after(self(), :refresh_reporting, 200)

        {:halt, assign(socket, :reporting_pending?, true)}

      :refresh_reporting, socket ->
        {:halt, socket |> assign(:reporting_pending?, false) |> refresh.()}

      :reporting_tick, socket ->
        Process.send_after(self(), :reporting_tick, 60_000)
        {:halt, refresh.(socket)}

      _, socket ->
        {:cont, socket}
    end)
  end
end
