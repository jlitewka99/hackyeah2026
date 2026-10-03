defmodule AiControlWeb.OrganizationOverviewLive do
  use AiControlWeb, :live_view

  alias AiControlWeb.OrganizationUI

  def mount(_, _, socket),
    do:
      {:ok,
       socket |> assign(:page_title, socket.assigns.current_scope.organization.name) |> refresh()}

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    permissions =
      Enum.map(
        socket.assigns.current_scope.grants.permissions,
        &%{id: &1, label: OrganizationUI.permission_name(&1)}
      )

    stream(socket, :permissions, permissions, reset: true)
  end
end
