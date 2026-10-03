defmodule AiControlWeb.OrganizationMemberAccessLive do
  use AiControlWeb, :live_view

  alias AiControl.Organizations
  alias AiControlWeb.OrganizationUI

  def mount(_, _, socket), do: {:ok, assign(socket, :page_title, "Member access")}
  def handle_params(%{"membership_id" => id}, _, socket), do: {:noreply, load(socket, id)}

  def handle_event("save", %{"access" => params}, socket) do
    attrs = %{role: params["role"] || "user", grants: OrganizationUI.grant_params(params)}

    case Organizations.update_member(
           socket.assigns.current_scope,
           socket.assigns.member.id,
           attrs
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Member access updated.")
         |> push_navigate(
           to: ~p"/organizations/#{socket.assigns.current_scope.organization.id}/members"
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, OrganizationUI.error_message(reason))}
    end
  end

  def handle_info({:organization_access_changed, _}, socket),
    do: {:noreply, load(socket, socket.assigns.member.id)}

  defp load(socket, id) do
    case Organizations.get_member(socket.assigns.current_scope, id) do
      {:ok, member} ->
        assign(socket,
          member: member,
          form: OrganizationUI.access_form(member.grants, member.role)
        )

      _ ->
        socket
        |> put_flash(:error, "This member cannot be managed with your current access.")
        |> push_navigate(
          to: ~p"/organizations/#{socket.assigns.current_scope.organization.id}/members"
        )
    end
  end
end
