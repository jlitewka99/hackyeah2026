defmodule AiControlWeb.OrganizationKnowledgeLive do
  use AiControlWeb, :live_view

  alias AiControl.Knowledge
  alias AiControl.Organizations.Grants
  alias AiControlWeb.ReportingHTML

  def mount(_, _, socket) do
    if connected?(socket),
      do:
        Phoenix.PubSub.subscribe(
          AiControl.PubSub,
          "organizations:#{socket.assigns.current_scope.organization.id}:knowledge"
        )

    {:ok,
     socket
     |> assign(
       page_title: "Knowledge",
       resource: nil,
       metadata: nil,
       error: nil,
       saving: false,
       page: 1,
       resource_count: 0,
       kind: "document",
       filter: %{"query" => "", "agent_id" => ""},
       filters_form: to_form(%{"query" => "", "agent_id" => ""}, as: :filters),
       form: to_form(defaults("document"), as: :resource),
       agents: []
     )
     |> allow_upload(:document, accept: ~w(.txt .md), max_entries: 1, max_file_size: 65_536)
     |> stream(:resources, [])}
  end

  def handle_params(params, _, socket) do
    kind = if params["kind"] == "memory", do: "memory", else: "document"
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(
        kind: kind,
        page: 1,
        error: nil,
        resource: nil,
        metadata: nil,
        agents: Knowledge.agent_options(scope)
      )

    socket = load_action(socket, params)

    {:noreply, refresh(socket)}
  end

  defp load_action(%{assigns: %{live_action: :new}} = socket, _) do
    scope = socket.assigns.current_scope

    if "knowledge.manage" in scope.grants.permissions,
      do: assign(socket, :form, to_form(defaults(socket.assigns.kind), as: :resource)),
      else:
        socket
        |> assign(:error, :forbidden)
        |> push_navigate(to: ~p"/organizations/#{scope.organization.id}/knowledge")
  end

  defp load_action(%{assigns: %{live_action: action}} = socket, params)
       when action in [:show, :edit] do
    scope = socket.assigns.current_scope

    case Knowledge.get(scope, params["resource_id"]) do
      {:ok, resource} ->
        load_checked(socket, resource)

      {:error, code} ->
        assign(socket, error: code, metadata: safe_metadata(scope, params["resource_id"]))
    end
  end

  defp load_action(socket, _), do: socket

  defp load_checked(socket, resource) do
    scope = socket.assigns.current_scope

    if socket.assigns.live_action == :edit && !manageable?(scope, resource) do
      socket
      |> assign(:error, :forbidden)
      |> push_navigate(
        to: ~p"/organizations/#{scope.organization.id}/knowledge/#{resource["id"]}"
      )
    else
      assign(socket,
        resource: resource,
        kind: resource["kind"],
        metadata: nil,
        form: to_form(resource, as: :resource)
      )
    end
  end

  defp safe_metadata(scope, id) do
    case Knowledge.metadata(scope, id) do
      {:ok, metadata} -> metadata
      _ -> nil
    end
  end

  defp read_upload(%{path: path}, _) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      _ -> {:ok, :invalid_upload}
    end
  end

  def handle_event("filter", %{"filters" => params}, socket) do
    params = Map.take(params, ~w(query agent_id))

    {:noreply,
     socket
     |> assign(page: 1, filter: params, filters_form: to_form(params, as: :filters))
     |> refresh()}
  end

  def handle_event("page", %{"direction" => direction}, socket) do
    page =
      if direction == "next", do: socket.assigns.page + 1, else: max(socket.assigns.page - 1, 1)

    {:noreply, socket |> assign(:page, page) |> refresh()}
  end

  def handle_event("validate", %{"resource" => params}, socket),
    do: {:noreply, assign(socket, :form, to_form(params, as: :resource))}

  def handle_event("save", %{"resource" => params}, socket) do
    scope = socket.assigns.current_scope
    resource = socket.assigns.resource

    attrs =
      params
      |> Map.take(~w(title content owner_agent_id source_reference trust_level))
      |> Map.put("kind", socket.assigns.kind)
      |> Map.put(
        "shared_agent_ids",
        List.wrap(params["shared_agent_ids"]) |> Enum.reject(&(&1 == ""))
      )

    attrs = if resource, do: Map.put(attrs, "revision", resource["revision"]), else: attrs

    {attrs, origin} =
      case consume_uploaded_entries(socket, :document, &read_upload/2) do
        [] -> {attrs, "manual"}
        [text] -> {Map.put(attrs, "content", text), "upload"}
      end

    {:noreply,
     socket
     |> assign(saving: true, error: nil, form: to_form(params, as: :resource))
     |> start_async(:save_resource, fn ->
       if resource,
         do: Knowledge.update(scope, resource["id"], attrs),
         else: Knowledge.create(scope, attrs, origin: origin)
     end)}
  end

  def handle_event("delete", _, socket) do
    resource = socket.assigns.resource || socket.assigns.metadata

    if resource && manageable?(socket.assigns.current_scope, resource) do
      id = resource["id"] || resource.id
      revision = resource["revision"] || resource.revision

      case Knowledge.delete(socket.assigns.current_scope, id, revision) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Resource deleted.")
           |> push_navigate(
             to: ~p"/organizations/#{socket.assigns.current_scope.organization.id}/knowledge"
           )}

        {:error, code} ->
          {:noreply, assign(socket, :error, code)}
      end
    else
      {:noreply, assign(socket, :error, :forbidden)}
    end
  end

  def handle_async(:save_resource, {:ok, {:ok, resource}}, socket) do
    {:noreply,
     socket
     |> assign(:saving, false)
     |> put_flash(:info, "Resource checked and saved.")
     |> push_navigate(
       to:
         ~p"/organizations/#{socket.assigns.current_scope.organization.id}/knowledge/#{resource["id"]}"
     )}
  end

  def handle_async(:save_resource, {:ok, {:error, code}}, socket),
    do: {:noreply, assign(socket, saving: false, error: code)}

  def handle_async(:save_resource, {:exit, _}, socket),
    do: {:noreply, assign(socket, saving: false, error: :guard_unavailable)}

  def handle_info(:knowledge_changed, socket) do
    {:noreply, invalidate(socket)}
  end

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, invalidate(socket)}

  defp invalidate(socket) do
    socket =
      assign(socket,
        resource: nil,
        metadata: nil,
        form: to_form(defaults(socket.assigns.kind), as: :resource)
      )

    if socket.assigns.live_action in [:show, :edit],
      do:
        push_navigate(socket,
          to: ~p"/organizations/#{socket.assigns.current_scope.organization.id}/knowledge"
        ),
      else: refresh(socket)
  end

  defp refresh(socket) do
    if socket.assigns.live_action == :index do
      filters = socket.assigns.filter
      params = %{"sources" => [socket.assigns.kind], "agent_id" => filters["agent_id"]}

      result =
        if String.trim(filters["query"] || "") == "" do
          Knowledge.list(
            socket.assigns.current_scope,
            Map.put(params, "page", socket.assigns.page)
          )
        else
          Knowledge.search(
            socket.assigns.current_scope,
            Map.put(params, "query", filters["query"])
          )
        end

      case result do
        {:ok, resources} ->
          socket
          |> stream(:resources, Enum.map(resources, &Map.put(&1, :id, &1["id"])), reset: true)
          |> assign(error: nil, resource_count: length(resources))

        {:error, code} ->
          socket |> stream(:resources, [], reset: true) |> assign(error: code, resource_count: 0)
      end
    else
      socket
    end
  end

  def manageable?(scope, resource) do
    owner = Map.get(resource, "owner_agent_id") || Map.get(resource, :owner_agent_id)

    "knowledge.manage" in scope.grants.permissions &&
      Grants.includes?(scope.grants.agents, owner)
  end

  def agent_name(agents, id),
    do: Enum.find_value(agents, id, fn {name, agent_id} -> if agent_id == id, do: name end)

  def error_message(:knowledge_disabled),
    do: "Knowledge is disabled in the active policy. Ask a policy manager to enable it."

  def error_message(:knowledge_write_disabled),
    do: "Memory writes are disabled in the active policy."

  def error_message(:policy_blocked),
    do: "The active policy blocked this content. Its text is unavailable."

  def error_message(:knowledge_conflict),
    do: "This resource changed. Refresh before saving again."

  def error_message(:input_too_large),
    do:
      "This operation exceeds a size limit. Search: 2 KiB; documents: 64 KiB; memory: 16 KiB; retrieved context: 128 KiB. Reduce the input or narrow your search."

  def error_message(_),
    do:
      "This resource could not be checked or accessed. Refresh and check your access and guard availability."

  defp defaults(kind),
    do: %{
      "kind" => kind,
      "title" => "",
      "content" => "",
      "owner_agent_id" => "",
      "source_reference" => "",
      "trust_level" => "untrusted",
      "shared_agent_ids" => []
    }
end
