defmodule AiControlWeb.GatewayControllerTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures
  import Ecto.Query
  import ExUnit.CaptureLog

  alias AiControl.{Gateway, Repo}
  alias AiControl.Gateway.Config
  alias AiControl.Policies.Configuration

  setup %{conn: conn} do
    old = Application.fetch_env!(:ai_control, Config)
    Application.put_env(:ai_control, Config, Keyword.put(old, :http_plug, {Req.Test, __MODULE__}))
    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    scope = organization_fixture()
    agent = agent_fixture(scope)
    {_key, token} = key_fixture(scope, agent)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    %{conn: conn, scope: scope, agent: agent}
  end

  test "authentication is required and liveness is independent", %{conn: conn} do
    assert build_conn() |> get("/v1/models") |> json_response(401)
    assert build_conn() |> get("/health") |> json_response(200) == %{"status" => "ok"}

    assert get(conn, "/v1/models") |> json_response(200) |> get_in(["data", Access.at(0), "id"]) ==
             "qwen3.5:4b"

    assert get(conn, "/ready") |> json_response(503) == %{"status" => "not_ready"}
  end

  test "invalid API keys share the remote IP limiter before authentication", context do
    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :ip_requests_per_minute, 1)
    )

    conn = %{build_conn() | remote_ip: {192, 0, 2, 91}}
    invalid = put_req_header(conn, "authorization", "Bearer invalid")
    assert invalid |> get("/v1/models") |> json_response(401)
    result = get(invalid, "/v1/models")
    assert json_response(result, 429)["error"]["code"] == "rate_limited"
    assert [retry] = get_resp_header(result, "retry-after")
    assert String.to_integer(retry) in 1..60

    refute Repo.exists?(
             from(b in AiControl.Budgets.Bucket,
               where: b.organization_id == ^context.scope.organization.id
             )
           )
  end

  test "hourly budget denials have distinct codes and UTC retry times", context do
    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :tokenizer, AiControl.TestBudgetTokenizer)
    )

    for {limits, code} <- [
          {%{"requests_per_hour" => 0}, "request_budget_exceeded"},
          {%{"tokens_per_hour" => 0}, "token_budget_exceeded"}
        ] do
      activate_gateway_policy(context.scope, %{"budgets" => %{"organization" => limits}})

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/tags" ->
            Req.Test.json(conn, %{
              models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
            })

          "/api/version" ->
            Req.Test.json(conn, %{version: "0.35.1"})

          _ ->
            Req.Test.json(conn, %{_debug_info: %{rendered_template: "prompt"}})
        end
      end)

      result = post(context.conn, "/v1/chat/completions", Jason.encode!(request()))
      assert json_response(result, 429)["error"]["code"] == code
      assert [retry] = get_resp_header(result, "retry-after")
      assert String.to_integer(retry) in 1..3600
    end
  end

  test "raw oversized, invalid JSON and unsupported payloads receive safe audited errors", %{
    conn: conn
  } do
    for {body, status, code} <- [
          {String.duplicate("s", 1_048_577), 413, "input_too_large"},
          {"{private_secret", 400, "invalid_request"},
          {Jason.encode!(Map.put(request(), "stream", "true")), 400, "invalid_request"}
        ] do
      result = post(conn, "/v1/chat/completions", body)
      data = json_response(result, status)
      assert data["error"]["code"] == code
      refute Jason.encode!(data) =~ "private_secret"
      assert Ecto.UUID.cast(data["error"]["request_id"]) |> elem(0) == :ok
      id = result.assigns.request_id

      assert Repo.exists?(
               from(e in AiControl.Audit.Event, where: e.kind == :gateway and e.request_id == ^id)
             )
    end
  end

  test "balanced guard failure is 503 and an explicit policy rejection is 403", context do
    assert post(context.conn, "/v1/chat/completions", Jason.encode!(request()))
           |> json_response(503)
           |> get_in(["error", "code"]) == "guard_unavailable"

    activate_gateway_policy(context.scope, %{"allowed_models" => []})

    assert post(context.conn, "/v1/chat/completions", Jason.encode!(request()))
           |> json_response(403)
           |> get_in(["error", "code"]) == "model_not_allowed"
  end

  test "limits and downstream errors have fixed status and no raw content in logs", context do
    activate_gateway_policy(context.scope)
    Application.put_env(:ai_control, Config, Config.get() |> Keyword.put(:requests_per_minute, 1))
    assert get(context.conn, "/v1/models") |> json_response(200)
    result = get(context.conn, "/v1/models")
    assert json_response(result, 429)["error"]["code"] == "rate_limited"
    assert [retry] = get_resp_header(result, "retry-after")
    assert String.to_integer(retry) in 1..60

    Application.put_env(
      :ai_control,
      Config,
      Config.get() |> Keyword.put(:requests_per_minute, 60)
    )

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{
            models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
          })

        _ ->
          Plug.Conn.send_resp(conn, 500, "PRIVATE_OUTPUT_SECRET")
      end
    end)

    logs =
      capture_log(fn ->
        conn = post(context.conn, "/v1/chat/completions", Jason.encode!(request()))
        assert json_response(conn, 502)["error"]["code"] == "upstream_rejected"
      end)

    refute logs =~ "PRIVATE_OUTPUT_SECRET"
    refute logs =~ "Zażółć"
  end

  test "ready requires every effective policy guard and verifies backend digests", context do
    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:models, %{"qwen3.5:4b" => String.duplicate("a", 64)})
      |> Keyword.put(
        :guards,
        Map.new(Configuration.guards(), &{&1, AiControl.TestGatewayGuard})
      )
    )

    Req.Test.stub(
      __MODULE__,
      &Req.Test.json(&1, %{models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]})
    )

    assert get(context.conn, "/ready") |> json_response(200) == %{"status" => "ready"}
    Application.put_env(:ai_control, Config, Keyword.put(Config.get(), :guards, %{}))
    assert get(context.conn, "/ready") |> json_response(503) == %{"status" => "not_ready"}

    assert {:error, :guard_unavailable} =
             Gateway.chat(principal_fixture(context.scope, context.agent), request())
  end
end
