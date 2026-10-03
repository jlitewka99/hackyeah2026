defmodule AiControlWeb.InvitationController do
  use AiControlWeb, :controller

  alias AiControl.Organizations.Invitations
  alias AiControlWeb.UserAuth

  def sign_in(conn, %{"token" => token}) do
    case Invitations.preview(token) do
      {:ok, _} ->
        conn
        |> put_session(:user_return_to, ~p"/invitations/#{token}")
        |> redirect(to: ~p"/users/log-in")

      _ ->
        conn
        |> put_flash(:error, "The invitation is invalid or has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def accept(conn, %{"user" => %{"token" => token} = attrs}) when is_binary(token) do
    case Invitations.accept(token, conn.assigns.current_scope, attrs) do
      {:ok, result} ->
        conn
        |> put_session(:user_return_to, ~p"/organizations/#{result.organization_id}")
        |> put_flash(:info, "You have joined the organization.")
        |> UserAuth.log_in_user(result.user)

      {:error, %Ecto.Changeset{}} ->
        retry(conn, token, "Password must be 12–72 characters and match its confirmation.")

      {:error, :authentication_required} ->
        conn
        |> put_session(:user_return_to, ~p"/invitations/#{token}")
        |> put_flash(:error, "Sign in with the invited account to continue.")
        |> redirect(to: ~p"/users/log-in")

      {:error, :wrong_account} ->
        retry(conn, token, "Sign in with the invited email to accept this invitation.")

      {:error, _} ->
        conn
        |> put_flash(:error, "The invitation is invalid or has expired.")
        |> redirect(to: ~p"/organizations")
    end
  end

  def accept(conn, _), do: send_resp(conn, :bad_request, "Invalid invitation request.")

  defp retry(conn, token, message),
    do: conn |> put_flash(:error, message) |> redirect(to: ~p"/invitations/#{token}")
end
