defmodule AiControlWeb.OrganizationRunsLive do
  use AiControlWeb, :live_view

  alias AiControl.Workflows
  alias AiControlWeb.ReportingLive

  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Workflows",
       filters: %{},
       form: to_form(%{}, as: :filters),
       next_cursor: nil,
       report_error: nil,
       runs_empty?: true
     )
     |> stream(:runs, [])
     |> updates()
     |> ReportingLive.install(&refresh/1)}
  end

  def handle_params(params, _, socket) do
    {:noreply,
     socket
     |> assign(
       filters: Map.take(params, ~w(status agent_id cursor)),
       form: to_form(params, as: :filters)
     )
     |> refresh()}
  end

  def handle_event("filter", %{"filters" => params}, socket) do
    case Workflows.page(socket.assigns.current_scope, params) do
      {:ok, _} ->
        {:noreply,
         push_patch(socket,
           to:
             ~p"/organizations/#{socket.assigns.current_scope.organization.id}/runs?#{Map.take(params, ~w(status agent_id))}"
         )}

      _ ->
        {:noreply,
         assign(socket,
           form: to_form(params, as: :filters),
           report_error: "Check the status and agent UUID, then try again."
         )}
    end
  end

  def handle_info(:workflows_changed, socket), do: {:noreply, refresh(socket)}
  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  defp updates(socket) do
    if connected?(socket),
      do:
        Phoenix.PubSub.subscribe(
          AiControl.PubSub,
          "organizations:#{socket.assigns.current_scope.organization.id}:workflows"
        )

    socket
  end

  defp refresh(socket) do
    case Workflows.page(socket.assigns.current_scope, socket.assigns.filters) do
      {:ok, page} ->
        socket
        |> assign(next_cursor: page.next, report_error: nil, runs_empty?: page.runs == [])
        |> stream(:runs, page.runs, reset: true)

      _ ->
        socket
        |> assign(
          next_cursor: nil,
          runs_empty?: false,
          report_error: "Workflows could not be loaded. Check the filters or try again shortly."
        )
        |> stream(:runs, [], reset: true)
    end
  end
end
