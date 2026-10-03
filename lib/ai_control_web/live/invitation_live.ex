defmodule AiControlWeb.InvitationLive do
  use AiControlWeb, :live_view

  alias AiControl.Accounts
  alias AiControl.Accounts.User
  alias AiControl.Organizations.Invitations
  alias AiControlWeb.OrganizationUI

  def mount(%{"token" => token}, _, socket) do
    case Invitations.preview(token) do
      {:ok, preview} ->
        {:ok,
         assign(socket,
           page_title: "Join organization",
           preview: preview,
           token: token,
           form: to_form(Accounts.change_user_password(%User{}, %{}, hash_password: false))
         )}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "The invitation is invalid or has expired.")
         |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  def handle_event("validate", %{"user" => attrs}, socket) do
    changeset =
      %User{}
      |> Accounts.change_user_password(attrs, hash_password: false)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end
end
