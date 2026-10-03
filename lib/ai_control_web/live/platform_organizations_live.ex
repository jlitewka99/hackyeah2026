defmodule AiControlWeb.PlatformOrganizationsLive do
  use AiControlWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Organizations")}
  end
end
