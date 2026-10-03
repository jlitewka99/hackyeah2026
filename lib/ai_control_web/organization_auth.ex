defmodule AiControlWeb.OrganizationAuth do
  @moduledoc "Organization authorization at both HTTP and every connected LiveView boundary."
  use AiControlWeb, :verified_routes

  import Phoenix.Component
  import Phoenix.Controller, only: [put_view: 2, render: 2]
  import Phoenix.LiveView
  import Plug.Conn, except: [assign: 3]

  alias AiControl.Organizations
  alias AiControl.Organizations.Access, as: OrganizationAccess
  alias AiControlWeb.UserAuth

  def require_organization(conn, _) do
    case Organizations.fetch_scope(
           conn.assigns.current_scope,
           conn.path_params["organization_id"]
         ) do
      {:ok, scope} ->
        Plug.Conn.assign(conn, :current_scope, scope)

      _ ->
        conn
        |> put_status(:not_found)
        |> put_view(html: AiControlWeb.ErrorHTML)
        |> render(:"404")
        |> halt()
    end
  end

  def require_manager(conn, _) do
    if Organizations.managers?(conn.assigns.current_scope) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> put_view(html: AiControlWeb.ErrorHTML)
      |> render(:"403")
      |> halt()
    end
  end

  def require_permission(conn, permission) do
    case OrganizationAccess.authorize(conn.assigns.current_scope, permission) do
      {:ok, scope} ->
        Plug.Conn.assign(conn, :current_scope, scope)

      _ ->
        conn
        |> put_status(:forbidden)
        |> put_view(html: AiControlWeb.ErrorHTML)
        |> render(:"403")
        |> halt()
    end
  end

  def on_mount(:require_organization, params, session, socket) do
    with {:cont, socket} <- UserAuth.on_mount(:require_authenticated, params, session, socket),
         {:cont, socket} <- load(socket, params["organization_id"]) do
      socket =
        socket
        |> attach_hook(:organization_params, :handle_params, fn params, _, socket ->
          load(socket, params["organization_id"])
        end)
        |> attach_hook(:organization_events, :handle_event, fn _, _, socket -> reload(socket) end)
        |> attach_hook(:organization_updates, :handle_info, fn _, socket -> reload(socket) end)

      {:cont, socket}
    end
  end

  defp reload(socket), do: load(socket, socket.assigns.current_scope.organization.id)

  defp load(socket, id) do
    previous = socket.assigns.current_scope.organization

    if connected?(socket) && (is_nil(previous) || previous.id != id) do
      if previous,
        do: Phoenix.PubSub.unsubscribe(AiControl.PubSub, "organizations:#{previous.id}:access")

      Phoenix.PubSub.subscribe(AiControl.PubSub, "organizations:#{id}:access")
    end

    case Organizations.fetch_scope(socket.assigns.current_scope, id) do
      {:ok, scope} ->
        check_page(assign(socket, :current_scope, scope))

      _ ->
        {:halt,
         socket
         |> put_flash(:error, "Organization access is no longer available.")
         |> redirect(to: ~p"/organizations")}
    end
  end

  defp check_page(socket) do
    manager_page? =
      socket.view in [
        AiControlWeb.OrganizationMembersLive,
        AiControlWeb.OrganizationMemberAccessLive
      ]

    permission = page_permission(socket.view)

    denied? =
      permission &&
        !match?({:ok, _}, OrganizationAccess.authorize(socket.assigns.current_scope, permission))

    if (manager_page? && !Organizations.managers?(socket.assigns.current_scope)) || denied? do
      {:halt,
       socket
       |> put_flash(:error, "Access to this page is no longer available.")
       |> redirect(to: ~p"/organizations/#{socket.assigns.current_scope.organization.id}")}
    else
      {:cont, socket}
    end
  end

  defp page_permission(AiControlWeb.OrganizationAgentsLive), do: "agents.read"
  defp page_permission(AiControlWeb.OrganizationApiKeysLive), do: "api_keys.read"
  defp page_permission(AiControlWeb.OrganizationPoliciesLive), do: "policies.read"
  defp page_permission(_), do: nil
end
