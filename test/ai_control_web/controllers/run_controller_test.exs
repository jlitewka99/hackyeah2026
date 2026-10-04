defmodule AiControlWeb.RunControllerTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.WorkflowsFixtures

  alias AiControl.Gateway.Config
  alias AiControl.Workflows

  setup do
    old = Application.fetch_env!(:ai_control, Config)

    Application.put_env(
      :ai_control,
      Config,
      old
      |> Keyword.put(:http_plug, {Req.Test, __MODULE__})
      |> Keyword.put(:tokenizer, AiControl.TestBudgetTokenizer)
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/models" ->
          Req.Test.json(conn, %{
            data: [%{id: "deepseek-flash"}]
          })

        _ ->
          Req.Test.json(conn, AiControl.GatewayFixtures.response())
      end
    end)

    :ok
  end

  test "authenticated API cycle uses root context and a delegate's own key", %{conn: conn} do
    c = workflow_fixture()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{c.token}")
      |> put_req_header("content-type", "application/json")

    key = Ecto.UUID.generate()

    created =
      conn
      |> put_req_header("idempotency-key", key)
      |> post("/v1/runs", Jason.encode!(%{goal: "Synthetic API cycle"}))
      |> json_response(201)

    same =
      conn
      |> put_req_header("idempotency-key", key)
      |> post("/v1/runs", Jason.encode!(%{goal: "Synthetic API cycle"}))
      |> json_response(201)

    assert same["run_id"] == created["run_id"]
    path = "/v1/runs/#{created["run_id"]}"

    bound =
      conn
      |> put_req_header("x-run-id", created["run_id"])
      |> put_req_header("x-run-participant-id", created["participant_id"])

    chat = AiControl.GatewayFixtures.request() |> Map.put("max_tokens", 4) |> Jason.encode!()
    assert bound |> post("/v1/chat/completions", chat) |> json_response(200)

    assert bound
           |> put_req_header("idempotency-key", Ecto.UUID.generate())
           |> post(
             "/v1/tool_calls",
             Jason.encode!(%{tool: "file.read", arguments: %{path: "report.txt"}})
           )
           |> json_response(200)

    target = agent_fixture(c.scope)
    {_, token} = key_fixture(c.scope, target)

    child =
      bound
      |> put_req_header("idempotency-key", Ecto.UUID.generate())
      |> post(path <> "/delegations", Jason.encode!(%{target_agent_id: target.id}))
      |> json_response(200)

    assert child["depth"] == 1
    delegated = conn |> put_req_header("authorization", "Bearer #{token}")
    data = get(delegated, path) |> json_response(200)
    assert Enum.map(data["participants"], & &1["id"]) == [child["participant_id"]]
    assert delegated |> post(path <> "/stop", "{}") |> json_response(403)

    assert delegated
           |> put_req_header("x-run-id", created["run_id"])
           |> put_req_header("x-run-participant-id", created["participant_id"])
           |> post("/v1/chat/completions", chat)
           |> json_response(403)

    assert delegated
           |> put_req_header("x-run-id", created["run_id"])
           |> put_req_header("x-run-participant-id", child["participant_id"])
           |> post("/v1/chat/completions", chat)
           |> json_response(200)

    assert get(conn, path) |> json_response(200) |> Map.fetch!("tokens") == 32

    assert conn |> post(path <> "/complete", "{}") |> json_response(200) |> Map.fetch!("status") ==
             "completed"

    assert get(conn, "/v1/runs") |> json_response(200) |> Map.fetch!("data") |> length() == 2
  end

  test "context errors and changed idempotent input have fixed status", %{conn: conn} do
    c = workflow_fixture()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{c.token}")
      |> put_req_header("content-type", "application/json")

    assert conn |> post("/v1/runs", Jason.encode!(%{goal: "Missing UUID"})) |> json_response(400)

    assert conn
           |> put_req_header("idempotency-key", Ecto.UUID.generate())
           |> post("/v1/runs", Jason.encode!(%{goal: String.duplicate("x", 241)}))
           |> json_response(400)

    assert conn
           |> put_req_header("idempotency-key", c.run.idempotency_key)
           |> post("/v1/runs", Jason.encode!(%{goal: "Changed"}))
           |> json_response(409)

    assert conn
           |> post("/v1/chat/completions", Jason.encode!(AiControl.GatewayFixtures.request()))
           |> json_response(400)
           |> get_in(["error", "code"]) == "workflow_context_required"

    assert conn
           |> put_req_header("x-run-id", c.run.id)
           |> post("/v1/chat/completions", "{}")
           |> json_response(400)

    assert conn
           |> put_req_header("x-run-id", c.run.id)
           |> post("/v1/tool_calls", "{}")
           |> json_response(400)

    {:ok, _} = Workflows.transition(c.principal, c.run.id, "stop")

    assert conn
           |> put_req_header("x-run-id", c.run.id)
           |> put_req_header("x-run-participant-id", c.participant.id)
           |> post("/v1/chat/completions", Jason.encode!(AiControl.GatewayFixtures.request()))
           |> json_response(409)
  end
end
