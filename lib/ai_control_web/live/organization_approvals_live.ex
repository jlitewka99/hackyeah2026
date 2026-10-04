defmodule AiControlWeb.OrganizationApprovalsLive do
  use AiControlWeb, :live_view

  alias AiControl.Approvals

  def mount(_, _, socket) do
    if connected?(socket),
      do:
        Phoenix.PubSub.subscribe(
          AiControl.PubSub,
          "organizations:#{socket.assigns.current_scope.organization.id}:approvals"
        )

    {:ok,
     socket
     |> assign(
       page_title: "Approvals",
       filters: %{},
       form: to_form(%{}, as: :filters),
       next_page: nil,
       empty?: true,
       error: nil
     )
     |> stream(:approvals, [])}
  end

  def handle_params(params, _, socket) do
    filters = Map.take(params, ~w(status kind agent_id run_id page))

    {:noreply,
     socket |> assign(filters: filters, form: to_form(filters, as: :filters)) |> refresh()}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    filters = Map.take(filters, ~w(status kind agent_id run_id))

    case Approvals.page(socket.assigns.current_scope, filters) do
      {:ok, _} ->
        {:noreply,
         push_patch(socket,
           to:
             ~p"/organizations/#{socket.assigns.current_scope.organization.id}/approvals?#{filters}"
         )}

      _ ->
        {:noreply,
         assign(socket, error: "Check the filters and enter valid agent and workflow UUIDs.")}
    end
  end

  def handle_info(:approvals_changed, socket), do: {:noreply, refresh(socket)}
  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    case Approvals.page(socket.assigns.current_scope, socket.assigns.filters) do
      {:ok, page} ->
        socket
        |> assign(error: nil, empty?: page.approvals == [], next_page: page.next)
        |> stream(:approvals, page.approvals, reset: true)

      _ ->
        socket
        |> assign(
          error: "Approvals could not be loaded. Check your filters and access, then try again.",
          empty?: false,
          next_page: nil
        )
        |> stream(:approvals, [], reset: true)
    end
  end
end
