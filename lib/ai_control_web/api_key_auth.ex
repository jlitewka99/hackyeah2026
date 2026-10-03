defmodule AiControlWeb.ApiKeyAuth do
  @moduledoc "Bearer authentication for agent requests; never accepts client-selected identities."
  import Plug.Conn

  alias AiControl.ApiKeys

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with [header] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         true <- String.downcase(scheme) == "bearer",
         {:ok, principal} <- ApiKeys.authenticate(token) do
      assign(conn, :api_principal, principal)
    else
      _ ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{error: %{code: "invalid_api_key", message: "Invalid API key."}})
        )
        |> halt()
    end
  end
end
