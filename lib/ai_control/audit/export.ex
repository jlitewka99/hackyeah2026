defmodule AiControl.Audit.Export do
  @moduledoc "Bounded-memory export. Completion confirms all authorized event batches."
  import Ecto.Query

  alias AiControl.Audit.{Filters, Serializer, WorkflowVisibility}
  alias AiControl.Organizations.Access
  alias AiControl.Repo

  def authorize(scope) do
    with {:ok, current} <- Access.authorize(scope, "events.read"),
         do: Access.authorize(current, "events.export")
  end

  def run(scope, filters, initial, send_batch) do
    with {:ok, current} <- authorize(scope) do
      Repo.transaction(fn -> stream(current, filters, initial, send_batch) end,
        timeout: 300_000,
        log: false
      )
    end
  rescue
    _ -> {:error, :export_interrupted}
  end

  defp stream(scope, filters, initial, send_batch) do
    %{rows: [["read committed"]]} = Repo.query!("SHOW transaction_isolation", [], log: false)
    query = Filters.query(scope.organization.id, filters) |> WorkflowVisibility.query(scope)
    query = order_by(query, [e], asc: e.occurred_at, asc: e.id)

    {state, count} =
      query
      |> Repo.stream(max_rows: 500, log: false)
      |> Stream.chunk_every(500)
      |> Enum.reduce({initial, 0}, &send_events(&1, &2, scope, send_batch))

    lines = [Jason.encode!(%{type: "export_complete", schema_version: 1, count: count}) <> "\n"]
    {send_checked(scope, state, lines, send_batch), count}
  end

  defp send_events(events, {state, count}, scope, send_batch) do
    lines =
      Enum.map(events, fn event ->
        Jason.encode!(%{type: "event", schema_version: 1, event: Serializer.event(event)}) <> "\n"
      end)

    {send_checked(scope, state, lines, send_batch), count + length(events)}
  end

  defp send_checked(scope, state, lines, send_batch) do
    with {:ok, current} <- authorize(scope),
         true <- current.grants == scope.grants,
         {:ok, state} <- send_batch.(state, lines) do
      state
    else
      _ -> Repo.rollback(:export_interrupted)
    end
  end
end
