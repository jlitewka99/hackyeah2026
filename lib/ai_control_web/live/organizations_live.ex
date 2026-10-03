defmodule AiControlWeb.OrganizationsLive do
  use AiControlWeb, :live_view

  alias AiControl.Organizations

  def mount(_, _, socket) do
    if connected?(socket),
      do:
        Phoenix.PubSub.subscribe(
          AiControl.PubSub,
          "users:#{socket.assigns.current_scope.user.id}:organizations"
        )

    {:ok, socket |> assign(:page_title, "Workspaces") |> refresh()}
  end

  def handle_info(:organizations_changed, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket),
    do:
      stream(
        socket,
        :organizations,
        Organizations.list_organizations(socket.assigns.current_scope), reset: true)
end
