defmodule AiControlWeb.OrganizationMembersLive do
  use AiControlWeb, :live_view

  alias AiControl.Gateway.Models
  alias AiControl.Organizations
  alias AiControl.Organizations.{Grants, Invitations}
  alias AiControlWeb.OrganizationUI

  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Members",
       invitation_form: to_form(Invitations.change_invitation(%{role: :user}), as: :invitation),
       access_form: OrganizationUI.access_form(%Grants{})
     )
     |> refresh()}
  end

  def handle_event("invite", %{"invitation" => invitation} = params, socket) do
    access = params["access"] || %{}
    attrs = Map.put(invitation, "grants", OrganizationUI.grant_params(access))
    socket = assign(socket, :access_form, OrganizationUI.submitted_access_form(access))

    case Invitations.issue(socket.assigns.current_scope, attrs, &url(~p"/invitations/#{&1}")) do
      {:ok, issued} ->
        {:noreply,
         socket
         |> assign(
           :invitation_form,
           to_form(Invitations.change_invitation(attrs), as: :invitation)
         )
         |> assign(:access_form, OrganizationUI.access_form(issued.grants, issued.role))
         |> put_flash(:info, "Invitation sent. It expires in 24 hours.")
         |> refresh()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :invitation_form, to_form(changeset, as: :invitation))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, OrganizationUI.error_message(reason))}
    end
  end

  def handle_event("remove", %{"id" => id}, socket),
    do:
      result(
        socket,
        Organizations.remove_member(socket.assigns.current_scope, id),
        "Member removed."
      )

  def handle_event("transfer", %{"id" => id}, socket),
    do:
      result(
        socket,
        Organizations.transfer_superadmin(socket.assigns.current_scope, id),
        "Superadmin role transferred."
      )

  def handle_event("revoke", %{"id" => id}, socket),
    do:
      result(socket, Invitations.revoke(socket.assigns.current_scope, id), "Invitation revoked.")

  def handle_event("resend", %{"id" => id}, socket),
    do:
      result(
        socket,
        Invitations.resend(socket.assigns.current_scope, id, &url(~p"/invitations/#{&1}")),
        "A new invitation has been sent."
      )

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  defp result(socket, {:ok, _}, message),
    do: {:noreply, socket |> put_flash(:info, message) |> refresh()}

  defp result(socket, {:error, reason}, _),
    do: {:noreply, put_flash(socket, :error, OrganizationUI.error_message(reason))}

  defp refresh(socket) do
    scope = socket.assigns.current_scope
    {:ok, members} = Organizations.list_members(scope)
    {:ok, invitations} = Organizations.list_invitations(scope)
    {:ok, agents} = AiControl.Agents.list_assignable_agents(scope)
    {:ok, models} = Models.list_assignable(scope)

    socket
    |> assign(:model_options, models)
    |> assign(:agent_options, Enum.map(agents, &{&1.name, &1.id}))
    |> assign(
      :role_options,
      if(Organizations.privileged?(scope),
        do: [{"User", "user"}, {"Admin", "admin"}],
        else: [{"User", "user"}]
      )
    )
    |> stream(:members, members, reset: true)
    |> stream(:invitations, invitations, reset: true)
  end
end
