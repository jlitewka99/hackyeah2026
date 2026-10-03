defmodule AiControlWeb.WorkspaceSwitcherComponent do
  @moduledoc "A searchable workspace selector shared by desktop and mobile navigation."
  use AiControlWeb, :live_component

  alias AiControl.Organizations

  @impl true
  def mount(socket) do
    {:ok, assign(socket, open?: false, query: "", configured?: false, form: search_form(""))}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns.configured? do
        socket
      else
        socket
        |> stream_configure(:workspaces, dom_id: &"#{assigns.id}-option-#{&1.id}")
        |> assign(:configured?, true)
      end

    {:ok, refresh(socket)}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    {:noreply, socket |> assign(:open?, !socket.assigns.open?) |> reset_search()}
  end

  def handle_event("open", _params, socket) do
    {:noreply, socket |> assign(:open?, true) |> reset_search()}
  end

  def handle_event("close", params, socket) do
    socket = assign(socket, :open?, false)

    socket =
      if params["return_focus"] == true do
        push_event(socket, "workspace-focus-trigger", %{id: "#{socket.assigns.id}-trigger"})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("search", %{"workspace_search" => %{"query" => query}}, socket) do
    {:noreply, socket |> assign(query: query, form: search_form(query)) |> refresh()}
  end

  defp reset_search(socket), do: socket |> assign(query: "", form: search_form("")) |> refresh()

  defp refresh(socket) do
    workspaces = Organizations.list_organizations(socket.assigns.current_scope)
    query = socket.assigns.query |> String.trim() |> String.downcase()
    results = Enum.filter(workspaces, &String.contains?(String.downcase(&1.name), query))

    socket
    |> assign(has_workspaces?: workspaces != [], result_count: length(results))
    |> stream(:workspaces, results, reset: true)
  end

  defp search_form(query) do
    {%{query: query}, %{query: :string}}
    |> Ecto.Changeset.change()
    |> to_form(as: :workspace_search)
  end
end
