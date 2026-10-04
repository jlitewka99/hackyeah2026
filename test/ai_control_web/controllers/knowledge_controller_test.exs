defmodule AiControlWeb.KnowledgeControllerTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.KnowledgeFixtures
  import AiControl.OrganizationsFixtures

  setup %{conn: conn} do
    scope = organization_fixture()
    agent = agent_fixture(scope)
    {_key, token} = key_fixture(scope, agent)
    activate_knowledge_policy(scope)

    api =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    %{scope: scope, agent: agent, api: api, session: log_in_user(conn, scope.user)}
  end

  test "agent memory CRUD enforces ownership and revision", c do
    created =
      post(
        c.api,
        "/v1/memory",
        Jason.encode!(%{title: "Preference", content: "support in English"})
      )
      |> json_response(201)

    id = created["data"]["id"]
    assert created["data"]["owner_agent_id"] == c.agent.id
    assert created["data"]["origin"] == "agent"
    assert get(c.api, "/v1/memory/#{id}") |> json_response(200)

    assert get(c.api, "/v1/memory") |> json_response(200) |> get_in(["data", Access.at(0), "id"]) ==
             id

    assert patch(
             c.api,
             "/v1/memory/#{id}",
             Jason.encode!(%{revision: 1, content: "support in Polish"})
           )
           |> json_response(200)
           |> get_in(["data", "revision"]) == 2

    assert patch(c.api, "/v1/memory/#{id}", Jason.encode!(%{revision: 1, content: "stale"}))
           |> json_response(409)

    assert delete(c.api, "/v1/memory/#{id}", Jason.encode!(%{revision: 2})) |> json_response(200)
    assert get(c.api, "/v1/memory/#{id}") |> json_response(403)
  end

  test "session API and agent search share checked storage", c do
    path = "/organizations/#{c.scope.organization.id}/knowledge/resources"
    result = post(c.session, path, document_attrs(c.agent)) |> json_response(201)
    id = result["data"]["id"]

    assert post(c.api, "/v1/knowledge/search", Jason.encode!(%{query: "support"}))
           |> json_response(200)
           |> get_in(["data", Access.at(0), "id"]) == id

    assert get(c.session, path <> "/#{id}") |> json_response(200)
    assert get(c.api, "/v1/memory/#{id}") |> json_response(403)
    assert get_resp_header(get(c.api, "/v1/memory"), "cache-control") == ["no-store"]
  end

  test "fixed failures do not echo input and authentication is required", c do
    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post("/v1/knowledge/search", "{}")
           |> json_response(401)

    assert post(
             c.api,
             "/v1/memory",
             Jason.encode!(%{
               owner_agent_id: Ecto.UUID.generate(),
               title: "private",
               content: "private"
             })
           )
           |> json_response(403)

    assert post(
             c.api,
             "/v1/knowledge/search",
             Jason.encode!(%{query: String.duplicate("x", 2049)})
           )
           |> json_response(413)

    assert post(c.api, "/v1/memory", "{PRIVATE_TEXT")
           |> json_response(400)
           |> Jason.encode!()
           |> String.contains?("PRIVATE_TEXT") == false

    reader =
      member_fixture(c.scope, :user, %{permissions: ["knowledge.read"], agents: [c.agent.id]})

    assert post(
             log_in_user(build_conn(), reader.user),
             "/organizations/#{c.scope.organization.id}/knowledge/resources",
             document_attrs(c.agent)
           )
           |> json_response(403)
  end

  test "session mutations require CSRF protection", c do
    conn = Plug.Conn.put_private(c.session, :plug_skip_csrf_protection, false)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(
        conn,
        "/organizations/#{c.scope.organization.id}/knowledge/resources",
        document_attrs(c.agent)
      )
    end
  end
end
