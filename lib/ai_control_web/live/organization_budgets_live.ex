defmodule AiControlWeb.OrganizationBudgetsLive do
  use AiControlWeb, :live_view

  alias AiControl.Dashboard
  alias AiControlWeb.{ReportingHTML, ReportingLive}

  def mount(_, _, socket),
    do:
      {:ok,
       socket |> assign(:page_title, "Budgets") |> ReportingLive.install(&refresh/1) |> refresh()}

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    report = Dashboard.budgets(socket.assigns.current_scope)

    budget =
      if ReportingHTML.ok?(report),
        do: ReportingHTML.value(report),
        else: %{agents: [], costs: []}

    socket
    |> assign(:report, report)
    |> stream(:agents, budget.agents, reset: true)
    |> stream(:costs, budget.costs, reset: true)
  end
end
