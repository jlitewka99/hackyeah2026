defmodule AiControlWeb.OrganizationRunLive do
  use AiControlWeb, :live_view

  alias AiControl.{Audit, Workflows}
  alias AiControl.Audit.Filters
  alias AiControl.Organizations.Access
  alias AiControlWeb.{ReportingLive, WorkflowHTML}

  def mount(_, _, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        AiControl.PubSub,
        "organizations:#{socket.assigns.current_scope.organization.id}:workflows"
      )

      Process.send_after(self(), :run_tick, 1000)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Workflow",
       run_id: nil,
       run: nil,
       usage: nil,
       remaining: 0,
       confirm_stop?: false,
       manage?: false,
       events?: false,
       report_error: nil,
       events_error: nil,
       events_empty?: true
     )
     |> stream(:participants, [])
     |> stream(:events, [])
     |> ReportingLive.install(&refresh/1)}
  end

  def handle_params(%{"run_id" => id}, _, socket),
    do: {:noreply, socket |> assign(:run_id, id) |> refresh()}

  def handle_event("request_stop", _, socket) do
    if match?(
         {:ok, _},
         Workflows.fetch(socket.assigns.current_scope, socket.assigns.run_id, "workflows.manage")
       ),
       do:
         {:noreply,
          socket
          |> assign(:confirm_stop?, true)
          |> push_event("workflow-focus", %{target: "confirm"})},
       else: {:noreply, refresh(socket)}
  end

  def handle_event("cancel_stop", _, socket),
    do:
      {:noreply,
       socket |> assign(:confirm_stop?, false) |> push_event("workflow-focus", %{target: "stop"})}

  def handle_event("stop", _, socket) do
    case Workflows.transition(socket.assigns.current_scope, socket.assigns.run_id, "stop") do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:confirm_stop?, false)
         |> put_flash(:info, "Workflow stopped. No further operations can start.")
         |> refresh()
         |> push_event("workflow-focus", %{target: "status"})}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "The workflow could not be stopped. Refresh and try again.")
         |> refresh()}
    end
  end

  def handle_info(:run_tick, socket) do
    Process.send_after(self(), :run_tick, 1000)
    remaining = if socket.assigns.run, do: WorkflowHTML.remaining(socket.assigns.run), else: 0
    {:noreply, assign(socket, :remaining, remaining)}
  end

  def handle_info(:workflows_changed, socket), do: {:noreply, refresh(socket)}
  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}
  defp refresh(%{assigns: %{run_id: nil}} = socket), do: socket

  defp refresh(socket) do
    scope = socket.assigns.current_scope

    with {:ok, run} <- Workflows.fetch(scope, socket.assigns.run_id),
         {:ok, participants} <- Workflows.participants(scope, run) do
      events? = match?({:ok, _}, Access.authorize(scope, "events.read"))
      {events, events_error} = event_data(scope, run, events?)

      socket
      |> assign(
        run: run,
        usage: Workflows.evidence(run),
        remaining: WorkflowHTML.remaining(run),
        manage?: match?({:ok, _}, Workflows.fetch(scope, run.id, "workflows.manage")),
        events?: events?,
        events_error: events_error,
        events_empty?: events == [],
        report_error: nil
      )
      |> stream(:participants, participants, reset: true)
      |> stream(:events, events, reset: true)
    else
      {:error, :workflow_unavailable} ->
        unavailable(socket)

      _ ->
        socket
        |> put_flash(:error, "This workflow is no longer available to your access.")
        |> push_navigate(to: ~p"/organizations/#{scope.organization.id}/runs")
    end
  rescue
    _ -> unavailable(socket)
  end

  defp unavailable(socket),
    do:
      assign(socket,
        report_error: "Workflow state is temporarily unavailable. Try refreshing.",
        manage?: false,
        confirm_stop?: false
      )

  defp event_data(_, _, false), do: {[], nil}

  defp event_data(scope, run, true) do
    case events(scope, run) do
      {:ok, entries} -> {entries, nil}
      _ -> {[], "Event history is temporarily unavailable."}
    end
  end

  defp events(scope, run) do
    {:ok, filters} =
      Filters.parse(%{
        "range" => "custom",
        "from" => DateTime.to_iso8601(DateTime.add(run.started_at, -1)),
        "to" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 1)),
        "run_id" => run.id
      })

    case Audit.page_events(scope, filters) do
      {:ok, page} -> {:ok, page.events}
      error -> error
    end
  rescue
    _ -> {:error, :audit_unavailable}
  end
end
