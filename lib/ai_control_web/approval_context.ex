defmodule AiControlWeb.ApprovalContext do
  @moduledoc "Strict transport references, separate from the operation payload."
  import Plug.Conn

  def parse(conn) do
    with {:ok, approval} <- reference(conn, "x-approval-id"),
         {:ok, key} <- reference(conn, "idempotency-key") do
      {:ok, [approval_id: approval, idempotency_key: key]}
    end
  end

  defp reference(conn, name) do
    case get_req_header(conn, name) do
      [] ->
        {:ok, nil}

      [value] ->
        case Ecto.UUID.cast(value) do
          {:ok, id} -> {:ok, id}
          _ -> {:error, :invalid_request}
        end

      _ ->
        {:error, :invalid_request}
    end
  end
end
