defmodule AiControl.Gateway.GuardsPipelineTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures
  import ExUnit.CaptureLog

  alias AiControl.Audit.Event
  alias AiControl.{Gateway, Policies, Repo}
  alias AiControl.Gateway.Config
  alias AiControl.Guards.{Ner, Pii, Secret, Signatures}
  alias AiControl.Policies.Configuration
  alias AiControl.Security.GuardResult
  alias Ecto.Adapters.SQL

  setup do
    original = Application.fetch_env!(:ai_control, Config)
    process = self()

    config =
      original
      |> Keyword.put(:guards, %{
        "pii" => Pii,
        "secret" => Secret,
        "signatures" => Signatures,
        "ner" => Ner,
        "semantic" => AiControl.TestSemanticGuard
      })
      |> Keyword.put(:http_plug, {Req.Test, :step7_backend})
      |> Keyword.put(:ner_http_plug, {Req.Test, :step7_ner})
      |> Keyword.put(:test_semantic_guard, fn fields, _ ->
        send(process, {:semantic, fields})
        GuardResult.new(%{guard: "semantic", status: :ok})
      end)

    Application.put_env(:ai_control, Config, config)
    on_exit(fn -> Application.put_env(:ai_control, Config, original) end)
    scope = organization_fixture()
    agent = agent_fixture(scope)
    principal = principal_fixture(scope, agent)

    Req.Test.stub(:step7_backend, fn conn ->
      send(process, {:backend, conn.request_path})

      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{
            models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
          })

        "/v1/chat/completions" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(process, {:generated_with, Jason.decode!(body)})
          Req.Test.json(conn, response("Safe reply."))
      end
    end)

    Req.Test.stub(:step7_ner, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      fields = Jason.decode!(body)["fields"]
      send(process, {:ner, Enum.map(fields, & &1["text"])})

      detections =
        Enum.flat_map(fields, fn field ->
          case :binary.match(field["text"], "Jan Kowalski") do
            {first, length} ->
              [
                %{
                  field_index: field["field_index"],
                  type: "person",
                  score: 0.85,
                  detector_id: "ner.person.v1",
                  start_byte: first,
                  end_byte: first + length
                }
              ]

            :nomatch ->
              []
          end
        end)

      Req.Test.json(conn, %{model_set: "pl-nkjp.v1", detections: detections})
    end)

    %{scope: scope, principal: principal}
  end

  defp activate(scope, overrides \\ %{}) do
    source = Configuration.default(2) |> Map.merge(overrides)
    {:ok, version} = Policies.create_version(scope, source)
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    version
  end

  test "deterministic redaction precedes NER, NER redaction precedes semantic and backend",
       context do
    activate(context.scope)

    input = %{
      request()
      | "messages" => [%{"role" => "user", "content" => "😀 Jan Kowalski: 44051401458"}]
    }

    assert {:ok, _} = Gateway.chat(context.principal, input)
    assert_received {:ner, fields}
    assert Enum.any?(fields, &(&1 == "😀 Jan Kowalski: [REDACTED]"))
    assert_received {:semantic, fields}
    assert Enum.any?(fields, &(&1 == "😀 [REDACTED]: [REDACTED]"))
    assert_received {:generated_with, data}
    assert hd(data["messages"])["content"] == "😀 [REDACTED]: [REDACTED]"
    events = Repo.all(Event)
    audit = events |> Enum.map(&Map.take(&1, Event.fields())) |> Jason.encode!()
    refute audit =~ "44051401458"
    refute audit =~ "Jan Kowalski"
    assert Enum.any?(events, &(get_in(&1.data, ["evaluated_guards"]) == ["ner"]))
  end

  test "secrets, exploits and strict PII block before sidecar and backend", context do
    activate(context.scope, %{"profile" => "strict"})

    for text <- ["password=DO-NOT-LOG", "pickle.loads(data)", "44051401458"] do
      logs =
        capture_log(fn ->
          assert {:error, :policy_blocked} =
                   Gateway.chat(context.principal, %{
                     request()
                     | "messages" => [%{"role" => "user", "content" => text}]
                   })
        end)

      refute logs =~ text
      refute_received {:ner, _}
      refute_received {:backend, _}
    end
  end

  test "required sidecar failure stops semantic and backend", context do
    activate(context.scope)
    Req.Test.stub(:step7_ner, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :guard_unavailable} = Gateway.chat(context.principal, request())
    refute_received {:semantic, _}
    refute_received {:backend, _}
  end

  test "activation during NER cannot change the in-flight snapshot", context do
    version = activate(context.scope)

    {:ok, next} =
      Policies.create_version(
        context.scope,
        Configuration.default(2) |> Map.put("profile", "strict")
      )

    parent = self()

    Req.Test.stub(:step7_ner, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      fields = Jason.decode!(body)["fields"]

      detections =
        Enum.flat_map(fields, fn field ->
          case :binary.match(field["text"], "Jan Kowalski") do
            {first, length} ->
              send(parent, {:ner_waiting, self()})

              receive do
                :resume -> :ok
              end

              [
                %{
                  field_index: field["field_index"],
                  type: "person",
                  score: 0.85,
                  detector_id: "ner.person.v1",
                  start_byte: first,
                  end_byte: first + length
                }
              ]

            :nomatch ->
              []
          end
        end)

      Req.Test.json(conn, %{model_set: "pl-nkjp.v1", detections: detections})
    end)

    task =
      Task.async(fn ->
        Gateway.chat(context.principal, %{
          request()
          | "messages" => [%{"role" => "user", "content" => "Jan Kowalski"}]
        })
      end)

    assert_receive {:ner_waiting, worker}
    {:ok, current} = Policies.current(context.scope)
    {:ok, _} = Policies.activate(context.scope, next.id, current.set.revision)
    send(worker, :resume)
    assert {:ok, _} = Task.await(task)
    assert_received {:generated_with, data}
    assert hd(data["messages"])["content"] == "[REDACTED]"
    decisions = Repo.all(Event) |> Enum.filter(&(&1.kind == :decision))
    assert decisions != []
    assert Enum.all?(decisions, &(&1.policy_checksum == version.checksum))
  end

  test "redaction that invalidates tool-call JSON stops before sidecar", context do
    activate(context.scope)

    message = %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        %{
          "id" => "call-1",
          "type" => "function",
          "function" => %{"name" => "lookup", "arguments" => ~s({"account":44051401458})}
        }
      ]
    }

    assert {:error, :redaction_unavailable} =
             Gateway.chat(context.principal, %{request() | "messages" => [message]})

    refute_received {:ner, _}
    refute_received {:backend, _}
  end

  test "a failed deterministic audit never sends text to NER", context do
    activate(context.scope)

    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT step7_no_decision CHECK (kind <> 'decision')",
      []
    )

    assert {:error, :audit_unavailable} = Gateway.chat(context.principal, request())
    refute_received {:ner, _}
    refute_received {:backend, _}
  end
end
