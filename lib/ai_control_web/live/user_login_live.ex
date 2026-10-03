defmodule AiControlWeb.UserLoginLive do
  use AiControlWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    {:ok,
     assign(socket,
       page_title: "Sign in",
       form: to_form(%{"email" => email, "remember_me" => false}, as: "user")
     )}
  end
end
