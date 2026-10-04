defmodule AiControlWeb.GatewayError do
  @moduledoc "Fixed public errors; upstream payloads and exceptions are never formatted."
  import Plug.Conn

  def respond(conn, {:error, {code, %{execution_id: id, execution_status: status}}})
      when code in [:tool_execution_exists, :idempotency_conflict] do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(
      409,
      Jason.encode!(%{
        error: %{
          code: Atom.to_string(code),
          message: "This execution key has already been used.",
          request_id: conn.assigns[:request_id],
          execution_id: id,
          execution_status: status
        }
      })
    )
  end

  def respond(conn, {:error, {:approval_required, evidence}}) when is_map(evidence) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(
      409,
      Jason.encode!(%{
        error:
          Map.merge(evidence, %{
            code: "approval_required",
            message: "Human approval is required before this operation can run.",
            request_id: conn.assigns[:request_id]
          })
      })
    )
  end

  def respond(conn, {:error, {code, retry_after}}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> respond({:error, code})
  end

  def respond(conn, {:error, code}) do
    {status, message} = classify(code)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Jason.encode!(%{
        error: %{
          code: Atom.to_string(code),
          message: message,
          request_id: conn.assigns[:request_id]
        }
      })
    )
  end

  def payload(code, request_id) do
    {_, message} = classify(code)
    %{error: %{code: Atom.to_string(code), message: message, request_id: request_id}}
  end

  defp classify(:workflow_context_required),
    do: {400, "A workflow run and participant are required."}

  defp classify(code) when code in [:workflow_terminal, :workflow_conflict],
    do: {409, "The workflow cannot accept this operation."}

  defp classify(:workflow_limit_exceeded),
    do: {429, "Workflow limit exceeded; the run has ended."}

  defp classify(:workflow_unavailable), do: {503, "Workflow state is temporarily unavailable."}

  defp classify(:invalid_request), do: {400, "Unsupported or invalid request."}
  defp classify(:approval_rejected), do: {403, "Human approval was rejected."}
  defp classify(:approval_expired), do: {409, "Human approval expired. Submit a new operation."}
  defp classify(:approval_used), do: {409, "Human approval has already been claimed or used."}

  defp classify(:approval_conflict),
    do: {409, "The approved operation changed or is no longer available. Submit a new operation."}

  defp classify(:knowledge_conflict), do: {409, "The resource changed. Refresh and try again."}

  defp classify(code) when code in [:knowledge_disabled, :knowledge_write_disabled],
    do: {403, "Knowledge operation is not allowed."}

  defp classify(code) when code in [:invalid_tool_request, :invalid_tool_arguments],
    do: {400, "Unsupported or invalid tool request."}

  defp classify(:tool_request_too_large), do: {413, "Tool request exceeds the size limit."}

  defp classify(code)
       when code in [
              :tool_not_allowed,
              :tool_resource_not_allowed,
              :tool_resource_not_found,
              :tool_redirect_blocked
            ], do: {403, "Tool request is not allowed."}

  defp classify(:tool_budget_exceeded), do: {429, "Tool context budget exceeded."}
  defp classify(:tool_timeout), do: {504, "Tool execution timed out."}

  defp classify(code) when code in [:tool_upstream_unavailable, :tool_invalid_result],
    do: {502, "Tool adapter returned an unusable response."}

  defp classify(:input_too_large), do: {413, "Request exceeds the configured size limit."}

  defp classify(code)
       when code in [
              :forbidden,
              :agent_not_allowed,
              :model_not_allowed,
              :policy_blocked,
              :redaction_unavailable
            ], do: {403, "Request is not allowed."}

  defp classify(:request_budget_exceeded), do: {429, "Hourly request budget exceeded."}
  defp classify(:token_budget_exceeded), do: {429, "Hourly token budget exceeded."}

  defp classify(code) when code in [:rate_limited, :capacity_exceeded],
    do: {429, "Gateway is busy. Try again later."}

  defp classify(:upstream_timeout), do: {504, "Model backend timed out."}

  defp classify(code)
       when code in [:upstream_rejected, :upstream_invalid_response, :response_too_large],
       do: {502, "Model backend returned an unusable response."}

  defp classify(_), do: {503, "Gateway is temporarily unavailable."}
end
