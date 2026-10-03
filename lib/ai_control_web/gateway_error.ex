defmodule AiControlWeb.GatewayError do
  @moduledoc "Fixed public errors; upstream payloads and exceptions are never formatted."
  import Plug.Conn

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

  defp classify(:invalid_request), do: {400, "Unsupported or invalid request."}
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
