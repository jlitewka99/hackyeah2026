defmodule AiControl.Gateway.PromptGuardPipelineTest do
  use AiControl.DataCase, async: false

  import AiControl.GatewayFixtures
  import AiControl.ToolsFixtures

  alias AiControl.{Audit, Dashboard, Gateway, Policies, Repo}
  alias AiControl.Audit.{Event, Filters, Serializer}
  alias AiControl.Gateway.Config
  alias AiControl.Gateway.Readiness
  alias AiControl.Guards.{Moderation, Semantic}
  alias AiControl.Guards.Semantic.{Local, PromptGuard}
  alias AiControl.Policies.Configuration

  setup do
    old = Application.fetch_env!(:ai_control, Config)
    parent = self()

    config =
      old
      |> Keyword.put(:guards, %{"semantic" => Semantic, "moderation" => Moderation})
      |> Keyword.put(:http_plug, {Req.Test, :pg_backend})
      |> Keyword.put(:prompt_guard_http_plug, {Req.Test, :pg_classifier})
      |> Keyword.put(:semantic_http_plug, {Req.Test, :qwen_moderation})

    Application.put_env(:ai_control, Config, config)
    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    context = tool_fixture()

    Req.Test.stub(:pg_backend, fn conn ->
      send(parent, {:backend, conn.request_path})

      if conn.request_path == "/api/tags",
        do:
          Req.Test.json(conn, %{
            models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
          }),
        else: Req.Test.json(conn, response("SAFE-OUTPUT"))
    end)

    Req.Test.stub(:pg_classifier, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      Req.Test.json(conn, %{
        model_set: PromptGuard.model_set(),
        revision: PromptGuard.revision(),
        task: "injection",
        duration_us: 1,
        windows:
          Enum.map(payload["fields"], fn field ->
            %{
              field_index: field["field_index"],
              start_byte: 0,
              end_byte: byte_size(field["text"]),
              score: if(String.contains?(field["text"], "ATTACK"), do: 0.9, else: 0.01)
            }
          end)
      })
    end)

    Req.Test.stub(:qwen_moderation, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      send(parent, {:moderation, payload["task"]})

      Req.Test.json(conn, %{
        model_set: Local.model_set(),
        revision: Local.revision(),
        task: payload["task"],
        duration_us: 1,
        windows:
          Enum.map(payload["fields"], fn field ->
            %{
              field_index: field["field_index"],
              start_byte: 0,
              end_byte: byte_size(field["text"]),
              severity: "Safe",
              categories: [],
              refusal: "Yes"
            }
          end)
      })
    end)

    guards =
      Map.new(Configuration.guards(4), &{&1, %{"enabled" => false, "required" => false}})
      |> Map.put("semantic", %{
        "enabled" => true,
        "required" => true,
        "provider" => "prompt_guard",
        "stages" => ["input", "output"]
      })
      |> Map.put("moderation", %{"enabled" => true, "required" => true})

    source =
      Configuration.default(4)
      |> Map.put("guards", guards)
      |> Map.put("tools", %{"allowed_tools" => ["file.read"]})

    {:ok, version} = Policies.create_version(context.scope, source)
    {:ok, current} = Policies.current(context.scope)
    {:ok, _} = Policies.activate(context.scope, version.id, current.set.revision)
    Map.put(context, :version, version)
  end

  test "chat and sandbox execution surface private scores and terminal accounting", context do
    assert {:ok, _} = Gateway.chat(context.principal, request())
    assert_received {:moderation, "moderation"}
    assert {:ok, _} = tool_call(context)
    assert {:ok, filters} = Filters.parse()

    assert {:ok, %{total: 2, counts: %{"allow" => 2}}} =
             Dashboard.activity(context.scope, filters)

    events =
      Repo.all(Event) |> Enum.filter(&(&1.organization_id == context.scope.organization.id))

    exported = Enum.map(events, &Serializer.event/1) |> Jason.encode!()
    assert exported =~ "classifier_score"
    assert exported =~ "label_mapping_binary"
    assert exported =~ "tool_execution"
    refute exported =~ "SAFE-OUTPUT"
    refute exported =~ "Zażółć"
    other = AiControl.OrganizationsFixtures.organization_fixture()
    assert {:ok, other_events} = Audit.list_events(other)
    assert Enum.all?(other_events, &(&1.organization_id == other.organization.id))
    refute Enum.any?(other_events, &(&1.kind in [:decision, :gateway]))
  end

  test "blocked injection and unavailable provider never contact downstream", context do
    assert {:error, :policy_blocked} =
             Gateway.chat(context.principal, %{
               request()
               | "messages" => [%{"role" => "user", "content" => "ATTACK"}]
             })

    refute_received {:backend, _}
    Req.Test.stub(:pg_classifier, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :guard_unavailable} = Gateway.chat(context.principal, request())
    refute_received {:backend, _}
  end

  test "readiness checks both providers across active policies", _context do
    parent = self()

    config =
      Config.get()
      |> Keyword.put(:models, %{"qwen3.5:4b" => String.duplicate("a", 64)})
      |> Keyword.update!(
        :guards,
        &Map.merge(&1, %{
          "pii" => AiControl.Guards.Pii,
          "secret" => AiControl.Guards.Secret,
          "signatures" => AiControl.Guards.Signatures
        })
      )

    Application.put_env(:ai_control, Config, config)

    Req.Test.stub(:pg_classifier, fn conn ->
      send(parent, :pg_readiness)

      Req.Test.json(conn, %{
        status: "ready",
        model_set: PromptGuard.model_set(),
        revision: PromptGuard.revision()
      })
    end)

    Req.Test.stub(:qwen_moderation, fn conn ->
      send(parent, :qwen_readiness)

      Req.Test.json(conn, %{
        status: "ready",
        model_set: Local.model_set(),
        revision: Local.revision()
      })
    end)

    assert :ok = Readiness.check()
    assert_received :pg_readiness
    assert_received :qwen_readiness

    Req.Test.stub(
      :pg_classifier,
      &Req.Test.json(&1, %{status: "ready", model_set: PromptGuard.model_set(), revision: "wrong"})
    )

    assert {:error, :not_ready} = Readiness.check()
  end

  test "provider activation cannot change an in-flight snapshot", context do
    parent = self()

    Req.Test.stub(:pg_classifier, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      send(parent, {:classifying, self()})

      receive do
        :resume -> :ok
      end

      Req.Test.json(conn, %{
        model_set: PromptGuard.model_set(),
        revision: PromptGuard.revision(),
        task: "injection",
        duration_us: 1,
        windows:
          Enum.map(
            payload["fields"],
            &%{
              field_index: &1["field_index"],
              start_byte: 0,
              end_byte: byte_size(&1["text"]),
              score: 0.01
            }
          )
      })
    end)

    {:ok, next} = Policies.create_version(context.scope, Configuration.default(4))
    supervisor = start_supervised!(Task.Supervisor)
    task = Task.Supervisor.async(supervisor, fn -> Gateway.chat(context.principal, request()) end)
    assert_receive {:classifying, worker}
    {:ok, current} = Policies.current(context.scope)
    {:ok, _} = Policies.activate(context.scope, next.id, current.set.revision)
    send(worker, :resume)
    assert_receive {:classifying, output_worker}
    send(output_worker, :resume)
    assert {:ok, _} = Task.await(task)

    decisions = Enum.filter(Repo.all(Event), &(&1.kind == :decision))
    assert length(decisions) == 2
    assert Enum.all?(decisions, &(&1.policy_checksum == context.version.checksum))
  end
end
