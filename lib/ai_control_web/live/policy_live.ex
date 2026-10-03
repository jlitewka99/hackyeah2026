defmodule AiControlWeb.PolicyLive do
  @moduledoc "Shared state transitions for organization and platform policy pages."
  import Ecto.Query
  import Phoenix.Component
  import Phoenix.LiveView

  alias AiControl.Agents.Agent
  alias AiControl.Organizations.Access
  alias AiControl.{Policies, Repo}
  alias AiControl.Policies.{Activation, Configuration, Draft}

  def mount(socket, target) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        AiControl.PubSub,
        Policies.topic(socket.assigns.current_scope, target)
      )

      if target == :organization,
        do: Phoenix.PubSub.subscribe(AiControl.PubSub, "platform:policies")
    end

    socket =
      socket
      |> assign(
        target: target,
        page_title: if(target == :global, do: "Global policy", else: "Policies"),
        editing?: false,
        errors: [],
        yaml_errors: [],
        preview: nil,
        preview_operation: :activate,
        review_stale?: false,
        changes: [],
        open_sections: MapSet.new(["resources"]),
        changed_elsewhere?: false,
        yaml_form: to_form(%{"text" => ""}, as: :yaml)
      )
      |> allow_upload(:policy_yaml,
        accept: ~w(.yaml .yml .json),
        max_entries: 1,
        max_file_size: 65_536
      )
      |> refresh()

    {:ok,
     assign(
       socket,
       :form,
       to_form(
         Draft.from_source(
           Map.get(socket.assigns, :current, %{version: %{configuration: Configuration.default()}}).version.configuration
         ),
         as: :policy
       )
     )}
  end

  def event("toggle_section", %{"section" => section}, socket)
      when section in ~w(effective guards resources budgets import) do
    sections = socket.assigns.open_sections

    sections =
      if MapSet.member?(sections, section),
        do: MapSet.delete(sections, section),
        else: MapSet.put(sections, section)

    {:noreply, assign(socket, :open_sections, sections)}
  end

  def event("new", _, socket) do
    {:noreply,
     assign(socket,
       editing?: true,
       errors: [],
       preview: nil,
       form: to_form(Draft.from_source(socket.assigns.current.version.configuration), as: :policy)
     )}
  end

  def event("upgrade", _, socket) do
    source = socket.assigns.form.source |> Draft.source() |> Configuration.upgrade()

    {:noreply,
     assign(socket,
       form: to_form(Draft.from_source(source), as: :policy),
       preview: nil,
       errors: []
     )}
  end

  def event("validate_yaml", %{"yaml" => attrs}, socket),
    do: {:noreply, assign(socket, :yaml_form, to_form(attrs, as: :yaml))}

  def event("cancel", _, socket),
    do: {:noreply, assign(socket, editing?: false, errors: [], preview: nil)}

  def event("validate", %{"policy" => attrs}, socket) do
    case Draft.validate(attrs) do
      {:ok, changeset, _} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :policy), errors: [])}

      {:error, changeset, errors} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :policy), errors: errors)}
    end
  end

  def event("save", %{"policy" => attrs}, socket) do
    case Draft.validate(attrs) do
      {:ok, changeset, config} ->
        case Policies.create_version(
               socket.assigns.current_scope,
               config.source,
               socket.assigns.target
             ) do
          {:ok, version} ->
            {:noreply,
             socket
             |> assign(form: to_form(changeset, as: :policy), editing?: false, errors: [])
             |> put_flash(:info, "Version saved. Review its changes before activation.")
             |> refresh()
             |> preview(version)}

          {:error, reason} ->
            failure(socket, reason)
        end

      {:error, changeset, errors} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :policy), errors: errors)}
    end
  end

  def event("view", %{"id" => id}, socket) do
    case Policies.get_version(socket.assigns.current_scope, id, socket.assigns.target) do
      {:ok, version} -> {:noreply, socket |> refresh() |> preview(version)}
      {:error, reason} -> failure(socket, reason)
    end
  end

  def event("copy", %{"id" => id}, socket) do
    case Policies.get_version(socket.assigns.current_scope, id, socket.assigns.target) do
      {:ok, version} ->
        {:noreply,
         assign(socket,
           editing?: true,
           preview: nil,
           errors: [],
           form: to_form(Draft.from_source(version.configuration), as: :policy)
         )}

      {:error, reason} ->
        failure(socket, reason)
    end
  end

  def event("activate", %{"id" => id}, socket), do: activate(socket, id, :activate)
  def event("rollback", %{"id" => id}, socket), do: activate(socket, id, :rollback)

  def event("refresh_review", _, socket) do
    {:noreply,
     socket
     |> refresh()
     |> assign(review_stale?: false, changed_elsewhere?: false)}
  end

  def event("review_rollback", %{"id" => id}, socket) do
    case Policies.get_version(socket.assigns.current_scope, id, socket.assigns.target) do
      {:ok, version} ->
        {:noreply,
         socket |> refresh() |> preview(version) |> assign(:preview_operation, :rollback)}

      {:error, reason} ->
        failure(socket, reason)
    end
  end

  def event("inherit", _, socket) do
    case Policies.inherit(socket.assigns.current_scope, socket.assigns.current.set.revision) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(preview: nil, changed_elsewhere?: false)
         |> put_flash(:info, "This organization now inherits the global policy.")
         |> refresh()}

      {:error, reason} ->
        failure(socket, reason)
    end
  end

  def event("import", %{"yaml" => attrs}, socket) do
    text = upload_text(socket) || attrs["text"]

    case Policies.import_yaml(text) do
      {:ok, source} ->
        {:noreply,
         socket
         |> assign(
           editing?: true,
           errors: [],
           yaml_errors: [],
           preview: nil,
           form: to_form(Draft.from_source(source), as: :policy),
           yaml_form: to_form(attrs, as: :yaml)
         )
         |> put_flash(:info, "YAML validated. Review and save a new version.")}

      {:error, errors} ->
        {:noreply, assign(socket, yaml_errors: errors, yaml_form: to_form(attrs, as: :yaml))}
    end
  end

  def event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :policy_yaml, ref)}

  def info(:policies_changed, socket) do
    previous = socket.assigns.current
    socket = refresh(socket, preserve_revision: true)
    changed? = socket.assigns.current.version.id != previous.version.id

    {:noreply,
     assign(socket,
       changed_elsewhere?: socket.assigns.changed_elsewhere? || changed?,
       review_stale?:
         socket.assigns.review_stale? || (changed? && !is_nil(socket.assigns.preview))
     )}
  end

  def info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}
  def info(_, socket), do: {:noreply, socket}

  defp activate(%{assigns: %{review_stale?: true}} = socket, _, _),
    do: failure(socket, :stale_policy)

  defp activate(socket, id, operation) do
    result =
      apply(Policies, operation, [
        socket.assigns.current_scope,
        id,
        socket.assigns.current.set.revision,
        socket.assigns.target
      ])

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(preview: nil, changed_elsewhere?: false)
         |> put_flash(:info, "Policy activated. New requests use this version.")
         |> refresh()}

      {:error, reason} ->
        failure(socket, reason)
    end
  end

  def refresh(socket, opts \\ []) do
    scope = socket.assigns.current_scope
    target = socket.assigns.target

    with {:ok, current} <- Policies.current(scope, target),
         {:ok, versions} <- Policies.list_versions(scope, target) do
      current =
        if opts[:preserve_revision] && socket.assigns[:current],
          do: %{current | set: %{current.set | revision: socket.assigns.current.set.revision}},
          else: current

      manage? = target == :global || match?({:ok, _}, Access.authorize(scope, "policies.manage"))

      agents =
        if target == :organization,
          do:
            Repo.all(
              from(a in Agent,
                where: a.organization_id == ^scope.organization.id,
                order_by: a.name
              )
            ),
          else: []

      set_id = current.set.id

      activations =
        Repo.all(
          from(a in Activation,
            where: a.set_id == ^set_id,
            order_by: [desc: a.revision]
          ),
          log: false
        )

      rows =
        Enum.map(versions, fn version ->
          last = Enum.find(activations, &(&1.version_id == version.id))

          %{
            id: version.id,
            version: version,
            active?: current.version.id == version.id,
            activation: last
          }
        end)

      socket
      |> assign(
        current: current,
        manage?: manage?,
        agents: agents,
        categories: Configuration.categories(),
        guards: Configuration.guards(),
        budget_fields: Configuration.budget_fields()
      )
      |> stream(:versions, rows, reset: true)
      |> clear_edit(manage?)
      |> refresh_preview()
    else
      _ -> redirect(socket, to: "/organizations")
    end
  end

  defp clear_edit(socket, true), do: socket
  defp clear_edit(socket, false), do: assign(socket, editing?: false, errors: [], preview: nil)

  defp preview(socket, version) do
    changes = diff(socket.assigns.current.version.settings, version.settings)

    assign(socket,
      preview: version,
      changes: changes,
      preview_operation: :activate,
      review_stale?: false
    )
  end

  defp refresh_preview(%{assigns: %{preview: nil}} = socket), do: socket

  defp refresh_preview(socket),
    do:
      assign(
        socket,
        :changes,
        diff(socket.assigns.current.version.settings, socket.assigns.preview.settings)
      )

  defp diff(before, after_settings) do
    old = flatten(before)
    new = flatten(after_settings)

    (Map.keys(old) ++ Map.keys(new))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reject(&(old[&1] == new[&1]))
    |> Enum.map(fn key ->
      %{path: key, before: Jason.encode!(old[key]), after: Jason.encode!(new[key])}
    end)
  end

  defp flatten(map, prefix \\ "") do
    Map.new(
      Enum.flat_map(map, fn {key, value} ->
        path = if prefix == "", do: key, else: "#{prefix}.#{key}"

        if is_map(value) && map_size(value) > 0,
          do: Map.to_list(flatten(value, path)),
          else: [{path, value}]
      end)
    )
  end

  defp upload_text(socket) do
    case uploaded_entries(socket, :policy_yaml) do
      {[], _} ->
        nil

      {_, []} ->
        socket
        |> consume_uploaded_entries(:policy_yaml, fn %{path: path}, _ ->
          {:ok, File.read!(path)}
        end)
        |> List.first()

      _ ->
        nil
    end
  end

  defp failure(socket, errors) when is_list(errors),
    do: {:noreply, assign(socket, :errors, errors)}

  defp failure(socket, reason) do
    message =
      case reason do
        :stale_policy ->
          "The active policy changed. Review the current version and try again."

        :audit_unavailable ->
          "The change could not be recorded. Nothing was activated; try again."

        :not_found ->
          "This version is not available. Refresh the page."

        _ ->
          "You no longer have permission to change this policy."
      end

    socket = socket |> put_flash(:error, message) |> assign(:changed_elsewhere?, false)

    socket =
      if reason == :stale_policy do
        socket |> assign(:review_stale?, true) |> refresh(preserve_revision: true)
      else
        refresh(socket)
      end

    {:noreply, socket}
  end
end
