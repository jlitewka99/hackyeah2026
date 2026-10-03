defmodule AiControlWeb.PolicyExportController do
  use AiControlWeb, :controller

  alias AiControl.Policies
  alias AiControl.Policies.YAML

  def organization(conn, %{"version_id" => id}) do
    scope = conn.assigns.current_scope
    # An inherited global version is readable through the organization's own URL.
    result =
      with {:ok, current} <- Policies.current(scope),
           true <- current.inherited? && current.version.id == id,
           do: {:ok, YAML.encode(current.version.configuration)}

    result = if match?({:ok, _}, result), do: result, else: Policies.export_yaml(scope, id)
    deliver(conn, result)
  end

  def platform(conn, %{"version_id" => id}),
    do: deliver(conn, Policies.export_yaml(conn.assigns.current_scope, id, :global))

  defp deliver(conn, {:ok, yaml}) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_download({:binary, yaml}, filename: "policy.yaml", content_type: "application/yaml")
  end

  defp deliver(conn, _) do
    conn |> put_status(:not_found) |> put_view(html: AiControlWeb.ErrorHTML) |> render(:"404")
  end
end
