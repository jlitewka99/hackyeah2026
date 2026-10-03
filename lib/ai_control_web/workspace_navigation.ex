defmodule AiControlWeb.WorkspaceNavigation do
  @moduledoc "Keeps the shared workspace switchers current on authenticated pages."

  import Phoenix.LiveView

  alias AiControlWeb.WorkspaceSwitcherComponent

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      user = socket.assigns.current_scope.user
      Phoenix.PubSub.subscribe(AiControl.PubSub, "users:#{user.id}:organizations")

      if user.organizer,
        do: Phoenix.PubSub.subscribe(AiControl.PubSub, "platform:organizations")
    end

    {:cont, attach_hook(socket, :workspace_navigation, :handle_info, &handle_info/2)}
  end

  defp handle_info(:organizations_changed, socket) do
    for id <- ["desktop-navigation-workspace-switcher", "mobile-navigation-workspace-switcher"] do
      send_update(WorkspaceSwitcherComponent, id: id, current_scope: socket.assigns.current_scope)
    end

    if socket.view in [AiControlWeb.OrganizationsLive, AiControlWeb.PlatformOrganizationsLive],
      do: {:cont, socket},
      else: {:halt, socket}
  end

  defp handle_info(_message, socket), do: {:cont, socket}
end
