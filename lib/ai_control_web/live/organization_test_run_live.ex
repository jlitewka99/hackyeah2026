defmodule AiControlWeb.OrganizationTestRunLive do
  use AiControlWeb, :live_view

  alias AiControl.Background
  alias AiControlWeb.{BackgroundHTML, ReportingLive}

  def mount(_, _, socket),
    do:
      {:ok,
       socket
       |> assign(page_title: "Test results", run_id: nil, run: nil)
       |> stream(:cases, [])
       |> ReportingLive.install(&refresh/1)}

  def handle_params(%{"run_id" => id}, _, socket),
    do: {:noreply, socket |> assign(:run_id, id) |> refresh()}

  def handle_event("cancel_run", %{"id" => id}, socket) do
    _ = Background.cancel(socket.assigns.current_scope, id)
    {:noreply, refresh(socket)}
  end

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}
  defp refresh(%{assigns: %{run_id: nil}} = socket), do: socket

  defp refresh(socket) do
    scope = socket.assigns.current_scope

    with {:ok, run} <- Background.fetch(scope, socket.assigns.run_id),
         true <- run.kind in ~w(gateway_tests benchmark),
         {:ok, cases} <- Background.cases(scope, run.id) do
      socket |> assign(:run, run) |> stream(:cases, cases, reset: true)
    else
      _ ->
        socket
        |> put_flash(:error, "This run is unavailable.")
        |> push_navigate(to: ~p"/organizations/#{scope.organization.id}/tests")
    end
  end
end
