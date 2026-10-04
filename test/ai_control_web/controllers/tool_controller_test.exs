defmodule AiControlWeb.ToolControllerTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.ToolsFixtures

  alias AiControl.Gateway.Config
  alias AiControl.Repo
  alias AiControl.Tools.Execution

  setup do
    tool_fixture()
  end

  test "endpoint authenticates before parsing and requires a single UUID key", context do
    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post("/v1/tool_calls", "invalid")
           |> json_response(401)

    for key <- [nil, "invalid", ""] do
      conn = agent_conn(context)
      conn = if key, do: put_req_header(conn, "idempotency-key", key), else: conn
      response = conn |> post("/v1/tool_calls", Jason.encode!(payload())) |> json_response(400)
      assert response["error"]["code"] == "invalid_request"
    end

    assert Repo.aggregate(Execution, :count) == 0
  end

  test "returns result and then 409 metadata without replay", context do
    key = Ecto.UUID.generate()
    first = call(context, payload(), key) |> json_response(200)
    assert first["result"] == %{"content" => "Zażółć gęślą jaźń"}
    repeated = call(context, payload(), key) |> json_response(409)
    assert repeated["error"]["execution_id"] == first["execution_id"]
    assert repeated["error"]["execution_status"] == "completed"
    refute Map.has_key?(repeated, "result")

    assert call(
             context,
             %{
               "tool" => "command.run",
               "arguments" => %{"command" => "status", "arguments" => []}
             },
             key
           )
           |> json_response(409)
           |> get_in(["error", "code"]) == "idempotency_conflict"
  end

  test "raw bytes and malformed payloads are bounded before general parser", context do
    for {body, status} <- [
          {String.duplicate("x", 65_537), 413},
          {"{invalid", 400},
          {Jason.encode!(Map.put(payload(), "organization_id", Ecto.UUID.generate())), 400},
          {Jason.encode!(Map.put(payload(), "agent_id", Ecto.UUID.generate())), 400}
        ] do
      response = call(context, body) |> json_response(status)
      refute Jason.encode!(response) =~ String.duplicate("x", 50)
    end

    assert Repo.aggregate(Execution, :count) == 0
  end

  test "tool quota has fixed 429 without suggesting an hourly refund", context do
    activate_tools(context.scope, %{"budgets" => %{"workflow" => %{"tool_calls" => 0}}})
    response = call(context, payload())
    assert json_response(response, 429)["error"]["code"] == "tool_budget_exceeded"
    assert get_resp_header(response, "retry-after") == []
  end

  test "IP and agent limiters reject malformed bodies before parsing", context do
    original = Application.fetch_env!(:ai_control, Config)
    on_exit(fn -> Application.put_env(:ai_control, Config, original) end)

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :ip_requests_per_minute, 1)
    )

    conn = %{
      put_req_header(build_conn(), "content-type", "application/json")
      | remote_ip: {192, 0, 2, 92}
    }

    assert post(conn, "/v1/tool_calls", "invalid") |> json_response(401)
    assert post(conn, "/v1/tool_calls", "invalid") |> json_response(429)

    Application.put_env(
      :ai_control,
      Config,
      original
      |> Keyword.put(:requests_per_minute, 1)
      |> Keyword.put(:ip_requests_per_minute, 10_000)
    )

    assert call(context, "invalid") |> json_response(400)
    assert call(context, "invalid") |> json_response(429)
    assert Repo.aggregate(Execution, :count) == 0
  end

  defp payload, do: %{"tool" => "file.read", "arguments" => %{"path" => "report.txt"}}

  defp agent_conn(context),
    do:
      build_conn()
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> put_req_header("content-type", "application/json")

  defp call(context, payload, key \\ nil),
    do:
      agent_conn(context)
      |> put_req_header("idempotency-key", key || Ecto.UUID.generate())
      |> post("/v1/tool_calls", if(is_binary(payload), do: payload, else: Jason.encode!(payload)))
end
