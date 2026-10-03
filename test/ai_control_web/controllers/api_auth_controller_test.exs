defmodule AiControlWeb.ApiAuthControllerTest do
  use AiControlWeb.ConnCase, async: true

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures
  import ExUnit.CaptureLog

  alias AiControl.{Agents, ApiKeys, Organizations}

  setup do
    scope = organization_fixture()
    agent = agent_fixture(scope)
    {key, token} = key_fixture(scope, agent)
    %{scope: scope, agent: agent, key: key, token: token}
  end

  test "Bearer identifies only the key's organization and agent, ignoring supplied identities", %{
    conn: conn,
    scope: scope,
    agent: agent,
    key: key,
    token: token
  } do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/v1/auth?organization_id=forged&agent_id=forged")

    assert json_response(conn, 200) == %{
             "organization_id" => scope.organization.id,
             "agent_id" => agent.id,
             "api_key_id" => key.id
           }

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    refute conn.assigns[:current_scope]
  end

  test "missing, malformed, wrong and ambiguous authorization returns the same 401", %{
    conn: conn,
    token: token
  } do
    forged =
      "aic_#{Ecto.UUID.generate()}_#{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}"

    headers = [
      [],
      [{"authorization", "Basic #{token}"}],
      [{"authorization", "Bearer #{forged}"}],
      [{"authorization", "Bearer"}],
      [{"authorization", "Bearer #{token} extra"}],
      [{"authorization", "Bearer #{token}"}, {"authorization", "Bearer #{token}"}],
      [{"authorization", "Bearer  #{token}"}]
    ]

    for extra_headers <- headers do
      response = get(%{conn | req_headers: extra_headers ++ conn.req_headers}, ~p"/v1/auth")

      assert json_response(response, 401) == %{
               "error" => %{"code" => "invalid_api_key", "message" => "Invalid API key."}
             }

      assert get_resp_header(response, "www-authenticate") == ["Bearer"]
      assert get_resp_header(response, "cache-control") == ["no-store"]
    end
  end

  test "revocation and suspension affect subsequent HTTP requests immediately", %{
    conn: conn,
    scope: scope,
    agent: agent,
    key: key,
    token: token
  } do
    authenticated = put_req_header(conn, "authorization", "Bearer #{token}")
    assert json_response(get(authenticated, ~p"/v1/auth"), 200)
    assert {:ok, _} = Agents.set_status(scope, agent.id, :suspended)
    assert json_response(get(authenticated, ~p"/v1/auth"), 401)
    assert {:ok, _} = Agents.set_status(scope, agent.id, :active)
    assert json_response(get(authenticated, ~p"/v1/auth"), 200)
    assert {:ok, _} = Organizations.set_status(scope, :suspended)
    assert json_response(get(authenticated, ~p"/v1/auth"), 401)
    assert {:ok, _} = Organizations.set_status(scope, :active)
    assert {:ok, _} = ApiKeys.revoke_key(scope, key.id)
    assert json_response(get(authenticated, ~p"/v1/auth"), 401)
  end

  test "a browser session cannot substitute for an API key", %{conn: conn, scope: scope} do
    conn = log_in_user(conn, scope.user) |> get(~p"/v1/auth")
    assert json_response(conn, 401)
  end

  test "authorization scheme is case-insensitive", %{conn: conn, token: token} do
    response = conn |> put_req_header("authorization", "bearer #{token}") |> get(~p"/v1/auth")
    assert json_response(response, 200)
  end

  test "authentication request logs and response never contain the token", %{
    conn: conn,
    token: token
  } do
    log =
      capture_log([level: :debug], fn ->
        response =
          conn
          |> put_req_header("authorization", "Bearer #{token}")
          |> get(~p"/v1/auth?secret=#{token}")

        assert json_response(response, 200)
        refute response.resp_body =~ token
      end)

    refute log =~ token
  end
end
