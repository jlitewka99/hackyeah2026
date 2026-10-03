defmodule AiControlWeb.OrganizationAgentsLive do
  use AiControlWeb, :live_view

  alias AiControl.Agents
  alias AiControl.Organizations.Access
  alias AiControlWeb.OrganizationUI

  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(page_title: "Agents", editing_id: nil, form: agent_form(), edit_form: agent_form())
     |> refresh()}
  end

  def handle_event("create", %{"agent" => attrs}, socket) do
    case Agents.create_agent(socket.assigns.current_scope, attrs) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(:form, agent_form()) |> put_flash(:info, "Agent created.") |> refresh()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :agent))}

      {:error, reason} ->
        failure(socket, reason)
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Agents.fetch_agent(socket.assigns.current_scope, id, "agents.manage") do
      {:ok, agent} ->
        {:noreply,
         socket
         |> assign(editing_id: id, edit_form: to_form(Agents.change_agent(agent), as: :agent))
         |> refresh()}

      {:error, reason} ->
        failure(socket, reason)
    end
  end

  def handle_event("cancel_edit", _, socket),
    do: {:noreply, socket |> assign(:editing_id, nil) |> refresh()}

  def handle_event("save", %{"agent" => attrs}, socket) do
    case Agents.update_agent(socket.assigns.current_scope, socket.assigns.editing_id, attrs) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(:editing_id, nil) |> put_flash(:info, "Agent updated.") |> refresh()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :edit_form, to_form(changeset, as: :agent))}

      {:error, reason} ->
        failure(socket, reason)
    end
  end

  def handle_event("status", %{"id" => id, "status" => status}, socket) do
    status =
      case status do
        "active" -> :active
        "suspended" -> :suspended
        _ -> nil
      end

    case Agents.set_status(socket.assigns.current_scope, id, status) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Agent status updated.") |> refresh()}
      {:error, reason} -> failure(socket, reason)
    end
  end

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    case Agents.list_agents(socket.assigns.current_scope) do
      {:ok, agents} -> refresh_agents(socket, agents)
      {:error, _} -> redirect(socket, to: ~p"/organizations")
    end
  end

  defp refresh_agents(socket, agents) do
    manage? = match?({:ok, _}, Access.authorize(socket.assigns.current_scope, "agents.manage"))

    editing_id =
      if manage? && Enum.any?(agents, &(&1.id == socket.assigns.editing_id)),
        do: socket.assigns.editing_id

    socket
    |> assign(
      manage?: manage?,
      create?: manage? && "*" in socket.assigns.current_scope.grants.agents,
      editing_id: editing_id
    )
    |> stream(:agents, agents, reset: true)
  end

  defp agent_form, do: to_form(Agents.change_agent(), as: :agent)

  defp failure(socket, reason),
    do: {:noreply, socket |> put_flash(:error, OrganizationUI.error_message(reason)) |> refresh()}
end
