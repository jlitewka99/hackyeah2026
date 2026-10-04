defmodule AiControlWeb.GatewayStreamControllerTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.KnowledgeFixtures
  import AiControl.OrganizationsFixtures
  import AiControl.WorkflowsFixtures
  import Ecto.Query

  alias AiControl.Audit.{Event, Filters, Serializer}
  alias AiControl.Budgets.{Bucket, Reservation}
  alias AiControl.{Dashboard, Repo}
  alias AiControl.Gateway.Config
  alias AiControl.Guards.Secret
  alias AiControl.Policies.Configuration
  alias Ecto.Adapters.SQL

  setup %{conn: conn} do
    Req.Test.set_req_test_to_shared()
    old = Application.fetch_env!(:ai_control, Config)

    config =
      old
      |> Keyword.put(:http_plug, {Req.Test, __MODULE__})
      |> Keyword.put(:tokenizer, AiControl.TestBudgetTokenizer)
      |> Keyword.put(:guards, %{"secret" => Secret})

    Application.put_env(:ai_control, Config, config)
    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    scope = organization_fixture()
    agent = agent_fixture(scope)
    {_key, token} = key_fixture(scope, agent)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "text/event-stream")

    policy(scope)
    backend(stream_body())
    %{conn: conn, scope: scope, agent: agent}
  end

  test "approved response emits public deltas, usage and DONE after safe audits", context do
    conn = chat(context.conn)
    assert conn.status == 200
    assert [type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(type, "text/event-stream")
    assert conn.resp_body =~ "data: [DONE]"
    assert conn.resp_body =~ "Bezpieczna odpowiedź"
    refute conn.resp_body =~ "backend-id"
    assert conn.resp_body =~ "\"usage\""
    events = events(conn.assigns.request_id)
    ready = Enum.find(events, &(&1.event_type == "gateway.stream_ready"))
    final = Enum.find(events, &(&1.event_type == "gateway.completed"))
    assert ready.data["budget"]["status"] == "settled"
    assert Serializer.data(final.data)["stream"]["delivery"] == "completed"
    assert final.data["stream"]["sent_chunks"] > 0
    assert final.data["timings"]["request"] == final.duration_us
    assert final.duration_us >= ready.duration_us
    assert Enum.count(events, &(&1.kind == :decision)) == 2
    assert bucket(context).tokens == 16
    assert bucket(context).reserved == 0
    assert {:ok, filters} = Filters.parse()
    assert {:ok, report} = Dashboard.activity(context.scope, filters)
    assert report.counts["allow"] == 1
  end

  test "RAG is checked and removed from the provider extension before buffered SSE", context do
    activate_knowledge_policy(context.scope, %{
      "budgets" => %{"organization" => %{"tokens_per_hour" => 5000}}
    })

    reference = run_reference_fixture(principal_fixture(context.scope, context.agent))

    context = %{
      context
      | conn:
          context.conn
          |> put_req_header("x-run-id", reference.run_id)
          |> put_req_header("x-run-participant-id", reference.participant_id)
    }

    document = document_fixture(context.scope, context.agent)
    owner = self()

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :test_tokenizer, fn _, prompt ->
        send(owner, {:rag_counted, prompt})
        {:ok, 40}
      end)
    )

    conn = chat(context.conn, %{"context" => %{"query" => "support"}})
    assert conn.resp_body =~ "[DONE]"
    assert_received {:stream_params, params}
    refute Map.has_key?(params, "context")

    assert [%{"name" => "retrieved_context", "content" => text}, %{"role" => "user"}] =
             params["messages"]

    assert text =~ document["id"]
    assert_received {:rag_counted, prompt}
    assert Jason.encode!(prompt) =~ "Support is available"
    assert prompt == params
    assert Repo.get_by!(Reservation, request_id: conn.assigns.request_id).input_tokens == 40
  end

  test "RAG revision changes during stream preparation prevent generation", context do
    activate_knowledge_policy(context.scope, %{
      "budgets" => %{"organization" => %{"tokens_per_hour" => 5000}}
    })

    reference = run_reference_fixture(principal_fixture(context.scope, context.agent))

    context = %{
      context
      | conn:
          context.conn
          |> put_req_header("x-run-id", reference.run_id)
          |> put_req_header("x-run-participant-id", reference.participant_id)
    }

    document = document_fixture(context.scope, context.agent)
    owner = self()

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :test_tokenizer, fn _, _ ->
        send(owner, {:rag_waiting, self()})

        receive do
          :continue -> {:ok, 40}
        end
      end)
    )

    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        chat(context.conn, %{"context" => %{"query" => "support"}})
      end)

    assert_receive {:rag_waiting, worker}

    Repo.update_all(
      from(r in AiControl.Knowledge.Resource, where: r.id == ^document["id"]),
      [inc: [revision: 1]],
      log: false
    )

    send(worker, :continue)
    conn = Task.await(task)
    assert json_response(conn, 409)["error"]["code"] == "knowledge_conflict"
    refute_received :stream_generated
    assert Repo.get_by!(Reservation, request_id: conn.assigns.request_id).status == "released"
  end

  test "split secret blocks output with an error event and charges actual usage", context do
    policy(context.scope, "block")
    backend(stream_body(["password=PRIVATE_", "STREAM_SECRET"]))
    conn = chat(context.conn)
    assert conn.status == 200
    assert conn.resp_body =~ "event: error"
    assert conn.resp_body =~ "policy_blocked"
    refute conn.resp_body =~ "[DONE]"
    refute conn.resp_body =~ "PRIVATE_"
    refute conn.resp_body =~ "password"
    assert bucket(context).tokens == 16
    assert bucket(context).reserved == 0

    refute events(conn.assigns.request_id) |> Enum.map(&Serializer.event/1) |> Jason.encode!() =~
             "STREAM_SECRET"
  end

  test "split secret is redacted before any public content", context do
    policy(context.scope, "redact")
    backend(stream_body(["password=PRIVATE_", "STREAM_SECRET"]))
    conn = chat(context.conn)
    assert conn.resp_body =~ "[REDACTED]"
    assert conn.resp_body =~ "[DONE]"
    refute conn.resp_body =~ "PRIVATE_"
  end

  test "usage is optional publicly and mandatory for accounting", context do
    conn = chat(context.conn, %{"stream_options" => %{"include_usage" => false}})
    refute conn.resp_body =~ "\"usage\""
    assert bucket(context).tokens == 16
    stream_body() |> String.replace(~r/,"usage":\{[^}]*\}/, "") |> backend()
    conn = chat(context.conn)
    assert conn.resp_body =~ "upstream_invalid_response"
    refute conn.resp_body =~ "[DONE]"
    assert Repo.get_by!(Reservation, request_id: conn.assigns.request_id).status == "uncertain"
  end

  test "input policy failure stays HTTP and starts no generation", context do
    policy(context.scope, "block")

    conn =
      chat(context.conn, %{
        "messages" => [%{"role" => "user", "content" => "password=INPUT_SECRET"}]
      })

    assert json_response(conn, 403)["error"]["code"] == "policy_blocked"
    refute_received :stream_generated
    assert bucket(context).reserved == 0
  end

  test "output audit failure sends no content and preserves settled usage", context do
    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT stream_reject_output CHECK (stage <> 'output')",
      []
    )

    conn = chat(context.conn)
    assert conn.resp_body =~ "audit_unavailable"
    refute conn.resp_body =~ "Bezpieczna"
    refute conn.resp_body =~ "[DONE]"
    assert bucket(context).tokens == 16
  end

  test "input audit failure stays HTTP and never dispatches", context do
    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT stream_reject_input CHECK (kind <> 'decision')",
      []
    )

    conn = chat(context.conn)
    assert json_response(conn, 503)["error"]["code"] == "audit_unavailable"
    refute_received :stream_generated
    assert bucket(context).reserved == 0
  end

  test "the synchronous readiness audit must succeed before the first public delta", context do
    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT stream_reject_ready CHECK (event_type <> 'gateway.stream_ready')",
      []
    )

    conn = chat(context.conn)
    assert conn.resp_body =~ "audit_unavailable"
    refute conn.resp_body =~ "Bezpieczna"
    refute conn.resp_body =~ "[DONE]"
    assert bucket(context).tokens == 16
  end

  test "required output guard failure does not disclose safe-looking provider content", context do
    policy(context.scope, "block", %{
      "ner" => %{"enabled" => true, "required" => true, "stages" => ["output"]}
    })

    conn = chat(context.conn)
    assert conn.resp_body =~ "guard_unavailable"
    refute conn.resp_body =~ "Bezpieczna"
    assert bucket(context).tokens == 16
  end

  test "invalid trailing data does not erase already received usage", context do
    backend(stream_body() <> "data: {}\n\n")
    conn = chat(context.conn)
    assert conn.resp_body =~ "upstream_invalid_response"
    refute conn.resp_body =~ "Bezpieczna"
    assert bucket(context).tokens == 16
    assert bucket(context).reserved == 0
  end

  test "fragmented tool arguments are checked and redacted as complete JSON", context do
    tools = [
      %{
        "type" => "function",
        "function" => %{"name" => "lookup", "parameters" => %{"type" => "object"}}
      }
    ]

    first = %{
      "index" => 0,
      "id" => "call_1",
      "type" => "function",
      "function" => %{"name" => "lookup", "arguments" => ~s({"password":"PRIVATE_)}
    }

    second = %{"index" => 0, "function" => %{"arguments" => ~s(STREAM_SECRET"})}}

    body =
      Enum.map_join(
        [
          stream_chunk(%{"role" => "assistant"}),
          stream_chunk(%{"tool_calls" => [first]}),
          stream_chunk(%{"tool_calls" => [second]}),
          stream_chunk(%{}, "tool_calls"),
          stream_usage(),
          "[DONE]"
        ],
        &("data: " <> &1 <> "\n\n")
      )

    backend(body)
    blocked = chat(context.conn, %{"tools" => tools})
    assert blocked.resp_body =~ "policy_blocked"
    refute blocked.resp_body =~ "PRIVATE_"
    refute blocked.resp_body =~ "[DONE]"

    policy(context.scope, "redact")
    accepted = chat(context.conn, %{"tools" => tools})

    calls =
      accepted.resp_body
      |> String.split("\n\n")
      |> Enum.filter(&String.starts_with?(&1, "data: {"))
      |> Enum.map(&(&1 |> String.replace_prefix("data: ", "") |> Jason.decode!()))
      |> Enum.flat_map(& &1["choices"])
      |> Enum.flat_map(&Map.get(&1["delta"], "tool_calls", []))

    assert [%{"index" => 0, "id" => "call_1", "function" => function}] = calls
    assert function["name"] == "lookup"
    assert Jason.decode!(function["arguments"]) == %{"password" => "[REDACTED]"}
    refute accepted.resp_body =~ "PRIVATE_"
    assert accepted.resp_body =~ "[DONE]"
    assert bucket(context).tokens == 32
  end

  test "invalid final usage refuses content and leaves dispatched tokens uncertain", context do
    backend(String.replace(stream_body(), "\"total_tokens\":16", "\"total_tokens\":-1"))
    conn = chat(context.conn)
    assert conn.resp_body =~ "upstream_invalid_response"
    refute conn.resp_body =~ "Bezpieczna"
    assert Repo.get_by!(Reservation, request_id: conn.assigns.request_id).status == "uncertain"
  end

  test "redaction growth is bounded before any approved data is delivered", context do
    policy(context.scope, "redact")
    body = stream_body([String.duplicate("password=x\n", 100)])
    backend(body)

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :response_bytes, byte_size(body) + 100)
    )

    conn = chat(context.conn)
    assert conn.resp_body =~ "response_too_large"
    refute conn.resp_body =~ "[REDACTED]"
    refute conn.resp_body =~ "[DONE]"
    assert bucket(context).tokens == 16
  end

  test "missing model stays HTTP and never starts the streamed generation", context do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{data: []}) end)

    conn = chat(context.conn)
    assert json_response(conn, 503)["error"]["code"] == "model_unavailable"
    refute_received :stream_generated
    assert bucket(context).reserved == 0
  end

  defp chat(conn, overrides \\ %{}),
    do:
      post(
        conn,
        "/v1/chat/completions",
        request()
        |> Map.merge(%{
          "stream" => true,
          "max_tokens" => 100,
          "stream_options" => %{"include_usage" => true}
        })
        |> Map.merge(overrides)
        |> Jason.encode!()
      )

  defp policy(scope, action \\ "block", extra_guards \\ %{}) do
    guards =
      Map.new(
        Configuration.guards(3),
        &{&1, %{"enabled" => false, "required" => false}}
      )
      |> Map.put("secret", %{"enabled" => true, "required" => true})
      |> Map.merge(extra_guards)

    activate_gateway_policy(scope, %{
      "schema_version" => 3,
      "guards" => guards,
      "rules" => %{"secret" => %{"action" => action}},
      "budgets" => %{"organization" => %{"tokens_per_hour" => 5000}}
    })
  end

  defp backend(body) do
    owner = self()

    Req.Test.stub(__MODULE__, &backend_request(&1, body, owner))
  end

  defp backend_request(conn, body, owner) do
    case conn.request_path do
      "/models" ->
        Req.Test.json(conn, %{data: [%{id: "deepseek-flash"}]})

      _ ->
        generate_response(conn, body, owner)
    end
  end

  defp generate_response(conn, body, owner) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    params = Jason.decode!(raw)

    send(owner, :stream_generated)
    send(owner, {:stream_params, params})
    assert params["stream_options"] == %{"include_usage" => true}

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, body)
  end

  defp bucket(context),
    do:
      Repo.get_by!(Bucket, organization_id: context.scope.organization.id, level: "organization")

  defp events(id),
    do: Repo.all(from(e in Event, where: e.request_id == ^id, order_by: e.occurred_at))
end
