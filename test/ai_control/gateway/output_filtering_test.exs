defmodule AiControl.Gateway.OutputFilteringTest do
  use AiControlWeb.ConnCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures
  import Ecto.Query
  import ExUnit.CaptureLog

  alias AiControl.{ApiKeys, Gateway, Policies, Repo}
  alias AiControl.Audit.Event
  alias AiControl.Gateway.Config
  alias AiControl.Guards.{Ner, Pii, Secret, Signatures}
  alias AiControl.Policies.Configuration
  alias AiControl.Security.GuardResult
  alias Ecto.Adapters.SQL

  setup %{conn: conn} do
    old = Application.fetch_env!(:ai_control, Config)
    owner = self()

    config =
      old
      |> Keyword.put(:guards, %{
        "pii" => Pii,
        "secret" => Secret,
        "signatures" => Signatures,
        "ner" => Ner,
        "semantic" => AiControl.TestSemanticGuard
      })
      |> Keyword.put(:http_plug, {Req.Test, :output_backend})
      |> Keyword.put(:ner_http_plug, {Req.Test, :output_ner})
      |> Keyword.put(:test_semantic_guard, fn fields, context ->
        send(owner, {:semantic, fields, context.stage})
        GuardResult.new(%{guard: "semantic", status: :ok})
      end)

    Application.put_env(:ai_control, Config, config)
    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)

    scope = organization_fixture()
    agent = agent_fixture(scope)
    {_key, token} = key_fixture(scope, agent)
    {:ok, principal} = ApiKeys.authenticate(token)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    backend(response())
    ner_stub()
    %{conn: conn, scope: scope, principal: principal}
  end

  test "safe text and multiple tool proposals preserve the public envelope and original usage",
       context do
    activate(context.scope)

    value =
      tool_response("Safe text.", [
        call(%{"query" => "safe"}),
        call(%{"query" => "other"}, "call-2")
      ])
      |> Map.put("private", "PRIVATE_REASONING")
      |> put_in(["choices", Access.at(0), "message", "reasoning"], "PRIVATE_REASONING")

    backend(value)
    result = chat(context.conn, tools_request()) |> json_response(200)
    assert result["usage"] == value["usage"]

    assert hd(result["choices"])["message"]["tool_calls"] ==
             hd(value["choices"])["message"]["tool_calls"]

    refute Jason.encode!(result) =~ "PRIVATE_REASONING"
    assert_received {:generated, _}
    refute_received {:generated, _}

    result["id"]
    |> String.replace_prefix("chatcmpl-", "")
    |> assert_terminal("completed", :output)
  end

  test "secrets and exploit signatures generated in text or escaped arguments block the whole response",
       context do
    activate(context.scope)

    cases = [
      response("password=PRIVATE_OUTPUT_SECRET"),
      response("pickle.loads(data)"),
      tool_response("Safe text.", [
        call(%{"query" => "safe"}),
        call(%{"password" => "PRIVATE_OUTPUT_SECRET"}, "call-2")
      ]),
      tool_response("Safe text.", [call_raw(~s({"passw\\u006frd":"PRIVATE_OUTPUT_SECRET"}))]),
      tool_response("Safe text.", [call_raw(~s|{"query":"pickle.\\u006coads(data)"}|)])
    ]

    for value <- cases do
      backend(value)

      logs =
        capture_log(fn ->
          conn = chat(context.conn, tools_request())
          error = json_response(conn, 403)["error"]
          assert error["code"] == "policy_blocked"
          assert error["message"] == "Request is not allowed."
          assert Map.keys(json_response(conn, 403)) == ["error"]
          assert_terminal(error["request_id"], "policy_blocked", :output)
        end)

      refute logs =~ "PRIVATE_OUTPUT_SECRET"
      refute logs =~ "pickle.loads"
      assert_received {:generated, _}
      refute_received {:generated, _}
      refute_received {:ner, _}
    end

    refute evidence() =~ "PRIVATE_OUTPUT_SECRET"
    refute evidence() =~ "pickle.loads"
  end

  test "PII is removed from text and every decoded argument without changing metadata", context do
    activate(context.scope)

    value =
      tool_response("😀 Kontakt: user@example.com", [
        call_raw(~s({"nested":[{"email":"user\\u0040example.com"}],"count":12})),
        call(%{"pesel" => "44051401458"}, "call-2")
      ])

    backend(value)
    result = chat(context.conn, tools_request()) |> json_response(200)
    message = hd(result["choices"])["message"]
    assert message["content"] == "😀 Kontakt: [REDACTED]"
    [first, second] = message["tool_calls"]

    assert Jason.decode!(first["function"]["arguments"]) == %{
             "nested" => [%{"email" => "[REDACTED]"}],
             "count" => 12
           }

    assert Jason.decode!(second["function"]["arguments"]) == %{"pesel" => "[REDACTED]"}
    assert result["usage"] == value["usage"]
    refute evidence() =~ "user@example.com"
    refute evidence() =~ "44051401458"
  end

  test "redaction violating a schema or targeting immutable data refuses everything", context do
    activate(context.scope)

    for value <- [
          tool_response("Safe.", [call(%{"value" => 44_051_401_458})]),
          tool_response("Safe.", [call(%{"user@example.com" => "safe"})]),
          tool_response("Safe.", [call(%{}, "44051401458")])
        ] do
      backend(value)
      error = chat(context.conn, tools_request()) |> json_response(403) |> Map.fetch!("error")
      assert error["code"] == "redaction_unavailable"
      assert_terminal(error["request_id"], "redaction_unavailable", :output)
    end

    backend(tool_response("Safe.", [call(%{"email" => "user@example.com"})]))

    schema = %{
      "type" => "object",
      "properties" => %{"email" => %{"type" => "string", "format" => "email"}}
    }

    assert chat(context.conn, tools_request(schema))
           |> json_response(403)
           |> get_in(["error", "code"]) == "redaction_unavailable"
  end

  test "malformed provider arguments and undeclared or disallowed proposals are 502", context do
    activate(context.scope)

    for {value, params} <- [
          {tool_response("Safe.", [call_raw("PRIVATE_INVALID_JSON")]), tools_request()},
          {tool_response("Safe.", [
             call_raw(~s({"query":"PRIVATE_DUPLICATE_VALUE","query":"safe"}))
           ]), tools_request()},
          {tool_response("Safe.", [
             call_raw(~s({"items":[{"query":"PRIVATE_DUPLICATE_VALUE","qu\\u0065ry":"safe"}]}))
           ]), tools_request()},
          {tool_response("Safe.", [call(%{})]), request()},
          {tool_response("Safe.", [call(%{})]), Map.put(tools_request(), "tool_choice", "none")},
          {response("Safe."), Map.put(tools_request(), "tool_choice", "required")},
          {tool_response("Safe.", [call(%{"count" => "bad"})]),
           tools_request(%{
             "type" => "object",
             "properties" => %{"count" => %{"type" => "integer"}}
           })}
        ] do
      backend(value)
      error = chat(context.conn, params) |> json_response(502) |> Map.fetch!("error")
      assert error["code"] == "upstream_invalid_response"
      assert_terminal(error["request_id"], "upstream_invalid_response", :output)
    end

    refute evidence() =~ "PRIVATE_INVALID_JSON"
    refute evidence() =~ "PRIVATE_DUPLICATE_VALUE"
  end

  test "gateway telemetry and logs never contain generated values or tool arguments", context do
    activate(context.scope)
    handler = Ecto.UUID.generate()

    :ok =
      :telemetry.attach_many(
        handler,
        [[:ai_control, :gateway, :request], [:ai_control, :gateway, :stage]],
        &__MODULE__.capture_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    backend(
      tool_response("PRIVATE_GENERATED_TEXT", [call(%{"password" => "PRIVATE_OUTPUT_SECRET"})])
    )

    logs = capture_log(fn -> assert chat(context.conn, tools_request()) |> json_response(403) end)
    events = telemetry_events([])
    assert events != []

    assert Enum.any?(events, fn {event, _, metadata} ->
             event == [:ai_control, :gateway, :request] &&
               metadata == %{code: "policy_blocked", stage: :output}
           end)

    for value <- ["PRIVATE_GENERATED_TEXT", "PRIVATE_OUTPUT_SECRET"] do
      refute logs =~ value
      refute inspect(events) =~ value
      refute evidence() =~ value
    end
  end

  test "invalid schemas and duplicate declarations fail before any backend request", context do
    activate(context.scope)
    invalid = tools_request(%{"type" => "object", "required" => "PRIVATE_SCHEMA_VALUE"})
    duplicate = Map.update!(tools_request(), "tools", &(&1 ++ &1))

    for params <- [invalid, duplicate] do
      error = chat(context.conn, params) |> json_response(400) |> Map.fetch!("error")
      assert error["code"] == "invalid_request"
      assert_terminal(error["request_id"], "invalid_request", :input)
    end

    refute_received {:backend, _}
    refute evidence() =~ "PRIVATE_SCHEMA_VALUE"
  end

  test "output phases and semantic adapter see only the current redacted text", context do
    activate(context.scope, ~w(pii secret signatures ner semantic))

    backend(
      tool_response("😀 Jan Kowalski: 44051401458", [
        call(%{"person" => "Jan Kowalski", "pesel" => "44051401458"})
      ])
    )

    result = chat(context.conn, tools_request()) |> json_response(200)
    assert_received {:ner, fields}
    assert "😀 Jan Kowalski: [REDACTED]" in fields
    assert "pesel: [REDACTED]" in fields
    assert_received {:semantic, fields, :output}
    assert "😀 [REDACTED]: [REDACTED]" in fields
    assert "person: [REDACTED]" in fields
    refute Enum.any?(fields, &String.contains?(&1, "Kowalski"))
    assert hd(result["choices"])["message"]["content"] == "😀 [REDACTED]: [REDACTED]"
    refute evidence() =~ "Kowalski"
  end

  test "schema validation uses the definitions actually sent after input redaction", context do
    guards =
      output_guards(~w(pii ner))
      |> Map.update!("pii", &Map.put(&1, "stages", ["input", "output"]))
      |> Map.update!("ner", &Map.put(&1, "stages", ["input", "output"]))

    activate_source(context.scope, Configuration.default(2) |> Map.put("guards", guards))
    schema = %{"type" => "object", "properties" => %{"person" => %{"const" => "Jan Kowalski"}}}
    backend(tool_response("Safe.", [call(%{"person" => "[REDACTED]"})]))
    assert chat(context.conn, tools_request(schema)) |> json_response(200)
    assert_received {:generated, sent}

    assert hd(sent["tools"])["function"]["parameters"]["properties"]["person"]["const"] ==
             "[REDACTED]"
  end

  test "required NER timeout and invalid UTF-8 ranges stop before semantic assessment", context do
    activate(context.scope, ~w(pii secret signatures ner semantic))
    backend(response("😀 Jan Kowalski"))

    for stub <- [
          fn conn -> Req.Test.transport_error(conn, :timeout) end,
          fn conn ->
            Req.Test.json(conn, %{
              model_set: "pl-nkjp.v1",
              detections: [
                %{
                  field_index: 0,
                  type: "person",
                  score: 0.85,
                  detector_id: "ner.person.v1",
                  start_byte: 1,
                  end_byte: 3
                }
              ]
            })
          end
        ] do
      Req.Test.stub(:output_ner, stub)
      error = chat(context.conn, request()) |> json_response(503) |> Map.fetch!("error")
      assert error["code"] == "guard_unavailable"
      assert_terminal(error["request_id"], "guard_unavailable", :output)
      refute_received {:semantic, _, _}
    end
  end

  test "failed intermediate, final and terminal audits never expose generated content", context do
    activate(context.scope, ~w(pii secret signatures ner semantic))
    backend(response("Jan Kowalski"))

    for {name, condition} <- [
          {"step8_phase", "stage <> 'output' OR NOT (data ? 'evaluated_guards')"},
          {"step8_final", "stage <> 'output' OR kind <> 'decision' OR data ? 'evaluated_guards'"},
          {"step8_terminal", "kind <> 'gateway'"}
        ] do
      SQL.query!(
        Repo,
        "ALTER TABLE audit_events ADD CONSTRAINT #{name} CHECK (#{condition}) NOT VALID",
        []
      )

      error = chat(context.conn, request()) |> json_response(503) |> Map.fetch!("error")
      assert error["code"] == "audit_unavailable"
      SQL.query!(Repo, "ALTER TABLE audit_events DROP CONSTRAINT #{name}", [])
    end

    refute evidence() =~ "Kowalski"
  end

  test "policy activation during generation preserves the held snapshot and tenant isolation",
       context do
    held = activate(context.scope, ~w(pii))
    owner = self()

    backend(fn ->
      send(owner, {:generating, self()})

      receive do
        :resume -> response("44051401458")
      end
    end)

    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Gateway.chat(context.principal, request())
      end)

    assert_receive {:generating, worker}
    activate(context.scope, ~w(pii), "strict")
    send(worker, :resume)
    assert {:ok, safe} = Task.await(task)
    id = String.replace_prefix(safe["id"], "chatcmpl-", "")
    decisions = Repo.all(from(e in Event, where: e.request_id == ^id and e.kind == :decision))
    assert Enum.all?(decisions, &(&1.policy_checksum == held.checksum))
    backend(response("44051401458"))
    assert chat(context.conn, request()) |> json_response(403)

    other = organization_fixture()
    activate(other, ~w(pii))
    principal = principal_fixture(other, agent_fixture(other))
    assert {:ok, safe} = Gateway.chat(principal, request())
    other_id = String.replace_prefix(safe["id"], "chatcmpl-", "")

    assert Repo.all(from(e in Event, where: e.request_id == ^other_id))
           |> Enum.all?(&(&1.organization_id == other.organization.id))
  end

  defp chat(conn, params), do: post(conn, "/v1/chat/completions", Jason.encode!(params))

  defp activate(scope, guards \\ ~w(pii secret signatures ner), profile \\ "balanced"),
    do:
      activate_source(
        scope,
        Configuration.default(2)
        |> Map.put("guards", output_guards(guards))
        |> Map.put("profile", profile)
      )

  defp activate_source(scope, source) do
    {:ok, version} = Policies.create_version(scope, source)
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    version
  end

  defp output_guards(enabled),
    do:
      Map.new(Configuration.guards(2), fn name ->
        {name,
         %{"enabled" => name in enabled, "required" => name in enabled, "stages" => ["output"]}}
      end)

  defp tools_request(schema \\ %{"type" => "object"}),
    do:
      Map.put(request(), "tools", [
        %{"type" => "function", "function" => %{"name" => "lookup", "parameters" => schema}}
      ])

  defp call(args, id \\ "call-1"), do: Map.put(call_raw(Jason.encode!(args)), "id", id)

  defp call_raw(args),
    do: %{
      "id" => "call-1",
      "type" => "function",
      "function" => %{"name" => "lookup", "arguments" => args}
    }

  defp tool_response(text, calls),
    do:
      response(text)
      |> put_in(["choices", Access.at(0), "message", "tool_calls"], calls)
      |> put_in(["choices", Access.at(0), "finish_reason"], "tool_calls")

  defp backend(value) do
    owner = self()
    Req.Test.stub(:output_backend, &backend_response(&1, value, owner))
  end

  defp backend_response(conn, value, owner) do
    send(owner, {:backend, conn.request_path})

    case conn.request_path do
      "/models" ->
        Req.Test.json(conn, %{data: [%{id: "deepseek-flash"}]})

      _ ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(owner, {:generated, Jason.decode!(body)})
        response = if is_function(value), do: value.(), else: value
        Req.Test.json(conn, response)
    end
  end

  defp ner_stub do
    owner = self()

    Req.Test.stub(:output_ner, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      fields = Jason.decode!(body)["fields"]
      send(owner, {:ner, Enum.map(fields, & &1["text"])})

      Req.Test.json(conn, %{
        model_set: "pl-nkjp.v1",
        detections: Enum.flat_map(fields, &ner_finding/1)
      })
    end)
  end

  defp ner_finding(field) do
    case :binary.match(field["text"], "Jan Kowalski") do
      {first, size} ->
        [
          %{
            field_index: field["field_index"],
            type: "person",
            score: 0.85,
            detector_id: "ner.person.v1",
            start_byte: first,
            end_byte: first + size
          }
        ]

      :nomatch ->
        []
    end
  end

  defp assert_terminal(id, code, stage) do
    assert Repo.exists?(
             from(e in Event,
               where:
                 e.request_id == ^id and e.kind == :gateway and e.stage == ^stage and
                   e.reason_codes == ^[code]
             )
           )
  end

  defp evidence, do: Repo.all(Event) |> Enum.map(&Map.take(&1, Event.fields())) |> Jason.encode!()

  def capture_telemetry(event, measurements, metadata, owner),
    do: send(owner, {:gateway_telemetry, event, measurements, metadata})

  defp telemetry_events(acc) do
    receive do
      {:gateway_telemetry, event, measurements, metadata} ->
        telemetry_events([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
