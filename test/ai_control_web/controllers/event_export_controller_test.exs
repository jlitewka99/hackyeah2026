defmodule AiControlWeb.EventExportControllerTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.OrganizationsFixtures

  alias AiControl.Audit

  test "download serializes the selected organization and ends with a completion count", %{
    conn: conn
  } do
    scope = organization_fixture()
    {:ok, _} = Audit.record_gateway(scope, Ecto.UUID.generate(), "completed", 1)

    conn =
      conn
      |> log_in_user(scope.user)
      |> get(~p"/organizations/#{scope.organization.id}/events/export?#{%{"kind" => "gateway"}}")

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "content-type") == ["application/x-ndjson; charset=utf-8"]
    lines = conn.resp_body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert [
             %{"event" => %{"organization_id" => id}},
             %{"type" => "export_complete", "count" => 1}
           ] = lines

    assert id == scope.organization.id
  end

  test "denies missing grants, another organization and malformed filters", %{conn: conn} do
    scope = organization_fixture()
    other = organization_fixture()
    reader = member_fixture(scope, :user, %{permissions: ["events.read"]})

    assert conn
           |> log_in_user(reader.user)
           |> get(~p"/organizations/#{scope.organization.id}/events/export")
           |> response(403)

    assert conn
           |> log_in_user(reader.user)
           |> get(~p"/organizations/#{other.organization.id}/events/export")
           |> response(404)

    assert conn
           |> log_in_user(scope.user)
           |> get(
             ~p"/organizations/#{scope.organization.id}/events/export?#{%{"agent_id" => "invalid"}}"
           )
           |> response(400)
  end
end
