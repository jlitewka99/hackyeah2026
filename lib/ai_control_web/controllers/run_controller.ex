defmodule AiControlWeb.RunController do
  use AiControlWeb, :controller

  alias AiControl.{Audit, Workflows}
  alias AiControl.Gateway.Limiter
  alias AiControlWeb.{ApprovalContext, GatewayError}

  plug :check_ingress

  def action(conn, _) do
    apply(__MODULE__, action_name(conn), [conn, conn.params])
  rescue
    _ -> GatewayError.respond(conn, {:error, :workflow_unavailable})
  catch
    :exit, _ -> GatewayError.respond(conn, {:error, :workflow_unavailable})
  end

  def create(conn, _) do
    case Workflows.create(
           conn.assigns.api_principal,
           conn.body_params,
           header(conn, "idempotency-key")
         ) do
      {:ok, {run, participant}} ->
        conn |> put_status(:created) |> json(Workflows.evidence(run, participant))

      error ->
        reject(conn, error)
    end
  end

  def index(conn, params) do
    case Workflows.page(conn.assigns.api_principal, params) do
      {:ok, page} ->
        json(conn, %{data: Enum.map(page.runs, &Workflows.evidence/1), next_cursor: page.next})

      error ->
        reject(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, run} <- Workflows.fetch(conn.assigns.api_principal, id),
         {:ok, participants} <- Workflows.participants(conn.assigns.api_principal, run) do
      json(
        conn,
        Map.put(
          Workflows.evidence(run),
          :participants,
          Enum.map(participants, &Map.take(&1, [:id, :agent_id, :parent_id, :depth]))
        )
      )
    else
      error -> reject(conn, error)
    end
  end

  def delegate(conn, %{"id" => id}) do
    case ApprovalContext.parse(conn) do
      {:ok, opts} -> delegate_with_approval(conn, id, opts)
      error -> reject(conn, error)
    end
  end

  defp delegate_with_approval(conn, id, opts) do
    case Workflows.delegate(
           conn.assigns.api_principal,
           id,
           header(conn, "x-run-participant-id"),
           conn.body_params,
           header(conn, "idempotency-key"),
           Keyword.put(opts, :request_id, conn.assigns.request_id)
         ) do
      {:ok, participant} ->
        json(conn, %{
          run_id: participant.run_id,
          participant_id: participant.id,
          depth: participant.depth
        })

      error ->
        reject(conn, error)
    end
  end

  def complete(conn, %{"id" => id}), do: transition(conn, id, "complete")
  def stop(conn, %{"id" => id}), do: transition(conn, id, "stop")

  defp transition(conn, id, action) do
    if conn.body_params == %{} do
      case Workflows.transition(conn.assigns.api_principal, id, action) do
        {:ok, run} -> json(conn, Workflows.evidence(run))
        error -> reject(conn, error)
      end
    else
      reject(conn, {:error, :invalid_request})
    end
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _ -> nil
    end
  end

  defp check_ingress(conn, _) do
    case if(conn.assigns[:gateway_ingress_checked],
           do: :ok,
           else: Limiter.check(conn.assigns.api_principal)
         ) do
      :ok -> conn
      error -> conn |> reject(error) |> halt()
    end
  end

  defp reject(conn, {:error, {code, _}} = error), do: reject_audited(conn, code, error)
  defp reject(conn, {:error, code} = error), do: reject_audited(conn, code, error)

  defp reject_audited(conn, code, error) do
    result =
      Audit.record_gateway(
        conn.assigns.api_principal,
        conn.assigns.request_id,
        Atom.to_string(code),
        0,
        nil,
        :input,
        nil,
        %{operation: "runs", timings: %{}}
      )

    GatewayError.respond(
      conn,
      if(match?({:ok, _}, result), do: error, else: {:error, :audit_unavailable})
    )
  end
end
