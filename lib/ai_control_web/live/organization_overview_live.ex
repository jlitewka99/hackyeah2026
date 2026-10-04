defmodule AiControlWeb.OrganizationOverviewLive do
  use AiControlWeb, :live_view

  alias AiControl.Audit.Filters
  alias AiControl.Dashboard
  alias AiControlWeb.OrganizationUI
  alias AiControlWeb.{ReportingHTML, ReportingLive}

  def mount(_, _, socket) do
    {:ok, filters} = Filters.parse()

    {:ok,
     socket
     |> assign(
       page_title: "Overview",
       filters: filters,
       form: to_form(Ecto.Changeset.change(filters), as: :filters)
     )
     |> ReportingLive.install(&refresh/1)
     |> refresh()}
  end

  def handle_params(params, _, socket) do
    case Filters.parse(params) do
      {:ok, filters} ->
        {:noreply,
         socket
         |> assign(filters: filters, form: to_form(Ecto.Changeset.change(filters), as: :filters))
         |> refresh()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :filters))}
    end
  end

  def handle_event("filter", %{"filters" => params}, socket) do
    case Filters.parse(params) do
      {:ok, filters} ->
        {:noreply,
         push_patch(socket,
           to:
             ~p"/organizations/#{socket.assigns.current_scope.organization.id}?#{Filters.params(filters)}"
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :filters))}
    end
  end

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    permissions =
      Enum.map(
        socket.assigns.current_scope.grants.permissions,
        &%{id: &1, label: OrganizationUI.permission_name(&1)}
      )

    {:ok, filters} = Filters.parse(Filters.params(socket.assigns.filters))
    reports = Dashboard.overview(socket.assigns.current_scope, filters)

    activity =
      if ReportingHTML.ok?(reports.activity),
        do: ReportingHTML.value(reports.activity),
        else: %{recent: [], latencies: [], detections: [], errors: []}

    controls =
      case reports.policy do
        {:ok, policy} ->
          Enum.map(policy.snapshot.settings["guards"], fn {id, settings} ->
            %{id: id, settings: settings}
          end)
          |> Enum.sort_by(& &1.id)

        _ ->
          []
      end

    socket
    |> assign(reports: reports, filters: filters)
    |> stream(:permissions, permissions, reset: true)
    |> stream(:recent_events, activity.recent, reset: true)
    |> stream(:latencies, activity.latencies, reset: true)
    |> stream(:detections, activity.detections, reset: true)
    |> stream(:service_errors, activity.errors, reset: true)
    |> stream(:controls, controls, reset: true)
  end
end
