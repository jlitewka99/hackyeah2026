defmodule AiControlWeb.PlatformOrganizationsLive do
  use AiControlWeb, :live_view

  alias AiControl.Organizations
  alias AiControl.Organizations.Invitations
  alias AiControlWeb.OrganizationUI

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(AiControl.PubSub, "platform:organizations")

    {:ok,
     socket
     |> assign(
       page_title: "Organizations",
       form: to_form(Organizations.change_organization()),
       invitation_form: to_form(Invitations.change_invitation(), as: :invitation)
     )
     |> refresh()}
  end

  @impl true
  def handle_event("create", %{"organization" => attrs}, socket) do
    case Organizations.create_organization(socket.assigns.current_scope, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Organizations.change_organization()))
         |> put_flash(:info, "Organization created. Invite its first superadmin below.")
         |> refresh()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, OrganizationUI.error_message(reason))}
    end
  end

  def handle_event("status", %{"id" => id, "status" => status}, socket)
      when status in ["active", "suspended"] do
    with {:ok, scope} <- Organizations.fetch_scope(socket.assigns.current_scope, id),
         {:ok, _} <-
           Organizations.set_status(scope, if(status == "active", do: :active, else: :suspended)) do
      {:noreply, socket |> put_flash(:info, "Organization status updated.") |> refresh()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Organization status could not be changed.")}
    end
  end

  def handle_event("invite-owner", %{"invitation" => attrs}, socket) do
    with {:ok, scope} <-
           Organizations.fetch_scope(socket.assigns.current_scope, attrs["organization_id"]),
         {:ok, _} <-
           Invitations.issue(
             scope,
             %{email: attrs["email"], role: :superadmin},
             &url(~p"/invitations/#{&1}")
           ) do
      {:noreply, socket |> put_flash(:info, "Superadmin invitation sent.") |> refresh()}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :invitation_form, to_form(changeset, as: :invitation))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, OrganizationUI.error_message(reason))}
    end
  end

  @impl true
  def handle_info(:organizations_changed, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    organizations = Organizations.list_organizations(socket.assigns.current_scope)

    socket
    |> assign(:organization_options, Enum.map(organizations, &{&1.name, &1.id}))
    |> stream(:organizations, organizations, reset: true)
  end
end
