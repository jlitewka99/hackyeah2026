defmodule AiControlWeb.UserConfirmationLive do
  use AiControlWeb, :live_view

  alias AiControl.Accounts

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      {:ok,
       assign(socket,
         page_title: "Restore access",
         user: user,
         form: to_form(%{"token" => token, "remember_me" => false}, as: "user")
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "The link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end
end
