defmodule AiControlWeb.RunContext do
  @moduledoc "Parse a pair of references, never a client-selected identity."
  import Plug.Conn

  alias AiControl.Audit
  alias AiControlWeb.GatewayError

  def reject(conn, operation) do
    result =
      Audit.record_gateway(
        conn.assigns.api_principal,
        conn.assigns.request_id,
        "invalid_request",
        0,
        nil,
        :input,
        nil,
        %{operation: operation, timings: %{}}
      )

    GatewayError.respond(
      conn,
      if(match?({:ok, _}, result),
        do: {:error, :invalid_request},
        else: {:error, :audit_unavailable}
      )
    )
  end

  def parse(conn) do
    case {get_req_header(conn, "x-run-id"), get_req_header(conn, "x-run-participant-id")} do
      {[], []} ->
        {:ok, nil}

      {[run], [participant]} ->
        with {:ok, run} <- Ecto.UUID.cast(run),
             {:ok, participant} <- Ecto.UUID.cast(participant),
             do: {:ok, %{run_id: run, participant_id: participant}},
             else: (_ -> {:error, :invalid_request})

      _ ->
        {:error, :invalid_request}
    end
  end
end
