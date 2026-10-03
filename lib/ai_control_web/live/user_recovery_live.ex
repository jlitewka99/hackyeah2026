defmodule AiControlWeb.UserRecoveryLive do
  use AiControlWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Recover access",
       form: to_form(%{"email" => ""}, as: "user")
     )}
  end
end
