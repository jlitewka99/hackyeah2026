defmodule AiControl.Gateway.SemanticPipelineTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures
  import ExUnit.CaptureLog

  alias AiControl.Audit.Event
  alias AiControl.{Gateway, Policies, Repo}
  alias AiControl.Gateway.Config
  alias AiControl.Guards.{Moderation, Pii, Secret, Semantic, Signatures}
  alias AiControl.Guards.Semantic.Local
  alias AiControl.Policies.Configuration

  setup do
    original = Application.fetch_env!(:ai_control, Config)
    parent = self()

    config =
      original
      |> Keyword.put(:guards, %{
        "pii" => Pii,
        "secret" => Secret,
        "signatures" => Signatures,
        "semantic" => Semantic,
        "moderation" => Moderation
      })
      |> Keyword.put(:http_plug, {Req.Test, :semantic_backend})
      |> Keyword.put(:semantic_http_plug, {Req.Test, :semantic_sidecar})

    Application.put_env(:ai_control, Config, config)
    on_exit(fn -> Application.put_env(:ai_control, Config, original) end)
    scope = organization_fixture()
    agent = agent_fixture(scope)
    principal = principal_fixture(scope, agent)

    Req.Test.stub(:semantic_backend, fn conn ->
      send(parent, {:backend, conn.request_path})

      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{
            models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
          })

        _ ->
          Req.Test.json(conn, response("Safe output"))
      end
    end)

    Req.Test.stub(:semantic_sidecar, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      send(parent, {:classified, payload})
      Req.Test.json(conn, classifier_response(payload))
    end)

    %{scope: scope, principal: principal}
  end

  defp activate(scope, extra \\ %{}) do
    guards = %{
      "ner" => %{"enabled" => false, "required" => false},
      "moderation" => %{"enabled" => true, "required" => true}
    }

    source = Configuration.default(3) |> Map.put("guards", guards) |> Map.merge(extra)
    {:ok, version} = Policies.create_version(scope, source)
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    version
  end

  defp classifier_response(payload) do
    windows =
      Enum.map(payload["fields"], fn field ->
        attack? = String.contains?(field["text"], "ATTACK")

        %{
          field_index: field["field_index"],
          start_byte: 0,
          end_byte: byte_size(field["text"]),
          severity: if(attack?, do: "Unsafe", else: "Safe"),
          categories:
            if(attack?,
              do: [if(payload["task"] == "injection", do: "Jailbreak", else: "Violent")],
              else: []
            ),
          refusal: if(payload["task"] == "moderation", do: "No")
        }
      end)

    %{
      model_set: Local.model_set(),
      revision: Local.revision(),
      task: payload["task"],
      windows: windows,
      duration_us: 5
    }
  end

  test "input injection stops before any backend call", context do
    activate(context.scope)

    assert {:error, :policy_blocked} =
             Gateway.chat(context.principal, %{
               request()
               | "messages" => [%{"role" => "user", "content" => "ATTACK"}]
             })

    refute_received {:backend, _}
  end

  test "moderation receives only sanitized input and blocks unsafe output", context do
    activate(context.scope)
    parent = self()

    Req.Test.stub(:semantic_backend, fn conn ->
      send(parent, {:backend, conn.request_path})

      if conn.request_path == "/api/tags",
        do:
          Req.Test.json(conn, %{
            models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
          }),
        else: Req.Test.json(conn, response("ATTACK output"))
    end)

    logs =
      capture_log(fn ->
        assert {:error, :policy_blocked} =
                 Gateway.chat(context.principal, %{
                   request()
                   | "messages" => [%{"role" => "user", "content" => "PESEL 44051401458"}]
                 })
      end)

    assert_received {:classified, %{"task" => "moderation", "prompt" => prompt}}
    assert prompt =~ "[REDACTED]"
    refute prompt =~ "44051401458"
    serialized = Repo.all(Event) |> Enum.map(&Map.take(&1, Event.fields())) |> Jason.encode!()
    refute serialized =~ "44051401458"
    refute serialized =~ "ATTACK output"
    refute logs =~ "44051401458"
    assert serialized =~ "label_mapping_binary"
    assert serialized =~ "content_safety"
  end

  test "incomplete scan and required timeout block and release the worker", context do
    activate(context.scope)

    Req.Test.stub(
      :semantic_sidecar,
      &Req.Test.json(&1, %{
        model_set: Local.model_set(),
        revision: Local.revision(),
        task: "injection",
        duration_us: 0,
        windows: []
      })
    )

    assert {:error, :guard_unavailable} = Gateway.chat(context.principal, request())
    refute_received {:backend, _}
    parent = self()

    Req.Test.stub(:semantic_sidecar, fn _ ->
      send(parent, {:worker, self()})

      receive do
        :resume -> raise "not expected"
      end
    end)

    Application.put_env(:ai_control, Config, Keyword.put(Config.get(), :semantic_timeout, 100))
    assert {:error, :guard_unavailable} = Gateway.chat(context.principal, request())
    assert_received {:worker, worker}
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    refute_received {:backend, _}
  end

  test "activation during classification preserves the snapshot for output", context do
    version = activate(context.scope)

    {:ok, next} =
      Policies.create_version(
        context.scope,
        Configuration.default(3) |> Map.put("profile", "strict")
      )

    parent = self()

    Req.Test.stub(:semantic_sidecar, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      if payload["task"] == "injection" do
        send(parent, {:waiting, self()})

        receive do
          :resume -> :ok
        end
      end

      Req.Test.json(conn, classifier_response(payload))
    end)

    supervisor = start_supervised!(Task.Supervisor)
    task = Task.Supervisor.async(supervisor, fn -> Gateway.chat(context.principal, request()) end)
    assert_receive {:waiting, worker}
    {:ok, current} = Policies.current(context.scope)
    {:ok, _} = Policies.activate(context.scope, next.id, current.set.revision)
    send(worker, :resume)
    assert {:ok, _} = Task.await(task)

    assert Enum.all?(
             Enum.filter(Repo.all(Event), &(&1.kind == :decision)),
             &(&1.policy_checksum == version.checksum)
           )
  end
end
