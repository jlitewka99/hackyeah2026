defmodule AiControlWeb.OrganizationTestsLive do
  use AiControlWeb, :live_view

  alias AiControl.Background
  alias AiControl.Background.Request
  alias AiControl.Testing.ProcessExecutor
  alias AiControlWeb.{BackgroundHTML, ReportingLive}

  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(page_title: "Tests", form: to_form(Request.changeset(), as: :test))
     |> ReportingLive.install(&refresh/1)
     |> refresh()}
  end

  def handle_event("run", %{"test" => params}, socket) do
    kind = if params["suite"] == "semantic-pl.v1", do: "benchmark", else: "gateway_tests"

    case Background.enqueue(socket.assigns.current_scope, kind, params) do
      {:ok, run} ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/organizations/#{socket.assigns.current_scope.organization.id}/tests/#{run.id}"
         )}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Choose a supported suite and mode. Running tests also requires tests.run access."
         )}
    end
  end

  def handle_event("cancel_run", %{"id" => id}, socket) do
    _ = Background.cancel(socket.assigns.current_scope, id)
    {:noreply, refresh(socket)}
  end

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    {:ok, runs} = Background.list(socket.assigns.current_scope, ~w(gateway_tests benchmark))

    socket
    |> assign(:runner_available?, ProcessExecutor.available?())
    |> stream(:runs, runs, reset: true)
  end
end
