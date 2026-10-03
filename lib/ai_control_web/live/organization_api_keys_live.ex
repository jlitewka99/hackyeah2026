defmodule AiControlWeb.OrganizationApiKeysLive do
  use AiControlWeb, :live_view

  alias AiControl.{Agents, ApiKeys}
  alias AiControl.Organizations.Access
  alias AiControlWeb.OrganizationUI

  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "API keys",
       form: key_form(),
       filter_form: to_form(%{"agent_id" => ""}, as: :filter),
       agent_filter: nil,
       selected_agent: nil,
       rotating_id: nil,
       revealed_key: nil,
       secret: nil
     )
     |> refresh()}
  end

  def handle_event("validate", %{"api_key" => attrs}, socket) do
    changeset = ApiKeys.change_key(attrs) |> Map.put(:action, :validate)

    {:noreply,
     assign(socket,
       form: to_form(changeset, as: :api_key),
       selected_agent: attrs["agent_id"] || socket.assigns.selected_agent
     )}
  end

  def handle_event("create", %{"api_key" => attrs}, socket) do
    result =
      if socket.assigns.rotating_id,
        do: ApiKeys.rotate_key(socket.assigns.current_scope, socket.assigns.rotating_id, attrs),
        else: ApiKeys.create_key(socket.assigns.current_scope, attrs["agent_id"], attrs)

    key_result(socket, result)
  end

  def handle_event("rotate", %{"id" => id}, socket) do
    with {:ok, keys} <- ApiKeys.list_keys(socket.assigns.current_scope),
         key when not is_nil(key) <- Enum.find(keys, &(&1.id == id)),
         {:ok, _} <-
           Access.authorize(socket.assigns.current_scope, "api_keys.manage", %{
             agent: key.agent_id
           }) do
      {:noreply,
       socket
       |> assign(
         rotating_id: id,
         selected_agent: key.agent_id,
         form: key_form(%{label: key.label}),
         revealed_key: nil,
         secret: nil
       )
       |> refresh()}
    else
      _ -> failure(socket, :forbidden)
    end
  end

  def handle_event("cancel_rotation", _, socket),
    do:
      {:noreply,
       socket |> assign(rotating_id: nil, selected_agent: nil, form: key_form()) |> refresh()}

  def handle_event("revoke", %{"id" => id}, socket) do
    case ApiKeys.revoke_key(socket.assigns.current_scope, id) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "API key revoked.") |> refresh()}
      {:error, reason} -> failure(socket, reason)
    end
  end

  def handle_event("filter", %{"filter" => %{"agent_id" => id}}, socket) do
    case ApiKeys.list_keys(socket.assigns.current_scope, id) do
      {:ok, keys} ->
        {:noreply,
         socket
         |> assign(agent_filter: id, filter_form: to_form(%{"agent_id" => id}, as: :filter))
         |> stream(:keys, keys, reset: true)}

      {:error, reason} ->
        failure(socket, reason)
    end
  end

  def handle_event("dismiss_secret", _, socket),
    do: {:noreply, assign(socket, revealed_key: nil, secret: nil)}

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  defp key_result(socket, {:ok, {key, secret}}) do
    {:noreply,
     socket
     |> assign(
       revealed_key: key,
       secret: secret,
       rotating_id: nil,
       selected_agent: nil,
       form: key_form()
     )
     |> put_flash(:info, "API key created. Copy it before leaving this page.")
     |> refresh()}
  end

  defp key_result(socket, {:error, %Ecto.Changeset{} = changeset}),
    do: {:noreply, assign(socket, :form, to_form(changeset, as: :api_key))}

  defp key_result(socket, {:error, reason}), do: failure(socket, reason)

  defp refresh(socket) do
    scope = socket.assigns.current_scope

    with {:ok, agents} <- Agents.list_for_permission(scope, "api_keys.read"),
         filter = retained_filter(agents, socket.assigns.agent_filter),
         {:ok, keys} <- ApiKeys.list_keys(scope, filter) do
      manage? = match?({:ok, _}, Access.authorize(scope, "api_keys.manage"))

      socket
      |> assign(
        manage?: manage?,
        agent_filter: filter,
        filter_form: to_form(%{"agent_id" => filter || ""}, as: :filter)
      )
      |> assign_agent_choices(agents)
      |> retain_sensitive_state(keys, manage?)
      |> stream(:keys, keys, reset: true)
    else
      _ -> socket |> assign(revealed_key: nil, secret: nil) |> redirect(to: ~p"/organizations")
    end
  end

  defp retained_filter(agents, filter) do
    if Enum.any?(agents, &(&1.id == filter)), do: filter
  end

  defp assign_agent_choices(socket, agents) do
    assign(socket,
      agent_options: Enum.map(agents, &agent_option/1),
      active_agent_options:
        agents |> Enum.filter(&(&1.status == :active)) |> Enum.map(&{&1.name, &1.id})
    )
  end

  defp agent_option(agent) do
    suffix = if agent.status == :suspended, do: " (suspended)", else: ""
    {agent.name <> suffix, agent.id}
  end

  defp retain_sensitive_state(socket, keys, manage?) do
    reveal? = reveal_allowed?(socket, manage?)

    rotating_id =
      if manage? && Enum.any?(keys, &rotatable?(&1, socket.assigns.rotating_id)),
        do: socket.assigns.rotating_id

    assign(socket,
      rotating_id: rotating_id,
      revealed_key: if(reveal?, do: socket.assigns.revealed_key),
      secret: if(reveal?, do: socket.assigns.secret)
    )
  end

  defp reveal_allowed?(%{assigns: %{revealed_key: nil}}, _), do: false

  defp reveal_allowed?(socket, manage?) do
    manage? &&
      match?(
        {:ok, _},
        Access.authorize(socket.assigns.current_scope, "api_keys.manage", %{
          agent: socket.assigns.revealed_key.agent_id
        })
      ) &&
      match?({:ok, _}, ApiKeys.authenticate(socket.assigns.secret))
  end

  defp rotatable?(key, id),
    do: key.id == id && ApiKeys.status(key) == :active && key.agent_status == :active

  defp key_form(attrs \\ %{}), do: to_form(ApiKeys.change_key(attrs), as: :api_key)

  defp failure(socket, reason),
    do: {:noreply, socket |> put_flash(:error, OrganizationUI.error_message(reason)) |> refresh()}
end
