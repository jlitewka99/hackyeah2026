defmodule AiControlWeb.ServerRequestId do
  @moduledoc "Server-generated correlation IDs cannot carry client-supplied secrets into logs."
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _) do
    conn
    |> Plug.Conn.delete_req_header("x-request-id")
    |> Plug.RequestId.call(
      Plug.RequestId.init(assign_as: :request_id, generator: &Ecto.UUID.generate/0)
    )
  end
end
