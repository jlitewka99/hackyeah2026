defmodule AiControlWeb.OrganizationApprovalLive do
  use AiControlWeb, :live_view

  alias AiControl.Approvals

  def mount(_, _, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        AiControl.PubSub,
        "organizations:#{socket.assigns.current_scope.organization.id}:approvals"
      )

      Process.send_after(self(), :expiry_tick, 5_000)
    end

    {:ok,
     assign(socket,
       page_title: "Review operation",
       approval_id: nil,
       approval: nil,
       preview: nil,
       preview_available?: false,
       manage?: false,
       confirmation: nil,
       decision_revision: nil,
       error: nil
     )
     |> stream(:history, [])}
  end

  def handle_params(%{"approval_id" => id}, _, socket),
    do: {:noreply, socket |> assign(approval_id: id) |> refresh()}

  def handle_event("request_decision", %{"action" => action}, socket)
      when action in ~w(approve reject) do
    socket = refresh(socket)

    if socket.assigns.manage? && socket.assigns.approval.status == "pending" &&
         socket.assigns.preview_available? do
      {:noreply,
       socket
       |> assign(confirmation: action, decision_revision: socket.assigns.approval.revision)
       |> push_event("approval-focus", %{id: "approval-confirm"})}
    else
      {:noreply,
       assign(socket, error: "This operation can no longer be reviewed. Refresh the page.")}
    end
  end

  def handle_event("cancel_decision", _, socket),
    do:
      {:noreply,
       socket
       |> assign(confirmation: nil)
       |> push_event("approval-focus", %{id: "approval-approve"})}

  def handle_event("decide", _, %{assigns: %{confirmation: action}} = socket)
      when action in ~w(approve reject) do
    result =
      Approvals.decide(
        socket.assigns.current_scope,
        socket.assigns.approval_id,
        if(action == "approve", do: :approve, else: :reject),
        socket.assigns.decision_revision
      )

    socket =
      socket
      |> assign(confirmation: nil)
      |> refresh()
      |> push_event("approval-focus", %{id: "approval-status"})

    case result do
      {:ok, _} ->
        {:noreply, socket}

      _ ->
        {:noreply,
         assign(socket,
           error:
             "The decision could not be saved. The operation may have changed, expired, or lost access. Review its current state."
         )}
    end
  end

  def handle_event("decide", _, socket), do: {:noreply, socket}
  def handle_info(:approvals_changed, socket), do: {:noreply, refresh(socket)}
  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  def handle_info(:expiry_tick, socket) do
    Process.send_after(self(), :expiry_tick, 5_000)
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    case Approvals.fetch(socket.assigns.current_scope, socket.assigns.approval_id) do
      {:ok, data} ->
        available? = match?({:ok, _}, data.preview)

        preview =
          case data.preview do
            {:ok, value} -> Jason.encode!(value, pretty: true)
            _ -> nil
          end

        confirmation =
          if data.approval.status == "pending" && available?, do: socket.assigns.confirmation

        socket
        |> assign(
          approval: data.approval,
          preview: preview,
          preview_available?: available?,
          manage?: Approvals.manageable?(socket.assigns.current_scope, data.approval),
          confirmation: confirmation,
          error: nil
        )
        |> stream(:history, data.history, reset: true)

      _ ->
        socket
        |> assign(
          approval: nil,
          preview: nil,
          preview_available?: false,
          manage?: false,
          confirmation: nil,
          error: "This approval is unavailable. Check your organization and assigned resources."
        )
        |> stream(:history, [], reset: true)
    end
  end
end
