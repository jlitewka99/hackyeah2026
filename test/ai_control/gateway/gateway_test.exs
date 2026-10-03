defmodule AiControl.GatewayTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.Audit.Event
  alias AiControl.{Gateway, Policies, Repo}
  alias AiControl.Gateway.{Config, Content}
  alias AiControl.Policies.Configuration
  alias AiControl.Security.{Detection, GuardResult}
  alias Ecto.Adapters.SQL

  setup do
    old = Application.fetch_env!(:ai_control, Config)
    Application.put_env(:ai_control, Config, Keyword.put(old, :http_plug, {Req.Test, __MODULE__}))
    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    scope = organization_fixture()
    agent = agent_fixture(scope)
    principal = principal_fixture(scope, agent)
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, {:backend, conn.request_path})

      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{
            models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
          })

        "/v1/chat/completions" ->
          Req.Test.json(conn, response())
      end
    end)

    %{scope: scope, agent: agent, principal: principal}
  end

  test "balanced fails closed before any backend request", %{principal: principal} do
    assert {:error, :guard_unavailable} = Gateway.chat(principal, request())
    refute_received {:backend, _}
    events = Repo.all(Event)
    assert Enum.any?(events, &(&1.kind == :decision && &1.action == :block))
    assert Enum.any?(events, &(&1.kind == :gateway && &1.reason_codes == ["guard_unavailable"]))
  end

  test "explicit local policy permits audited input and output with no content in evidence",
       context do
    activate_gateway_policy(context.scope)
    id = Ecto.UUID.generate()
    assert {:ok, data} = Gateway.chat(context.principal, request(), request_id: id)
    assert data["choices"] |> hd() |> get_in(["message", "content"]) == "Bezpieczna odpowiedź"
    assert_received {:backend, "/api/tags"}
    assert_received {:backend, "/v1/chat/completions"}
    events = Repo.all(from(e in Event, where: e.request_id == ^id))
    assert Enum.sort(Enum.map(events, & &1.kind)) == [:decision, :decision, :gateway]

    assert Enum.sort(Enum.map(Enum.filter(events, &(&1.kind == :decision)), & &1.stage)) == [
             :input,
             :output
           ]

    refute events |> Enum.map(&Map.take(&1, Event.fields())) |> Jason.encode!() =~ "Zażółć"

    refute events |> Enum.map(&Map.take(&1, Event.fields())) |> Jason.encode!() =~
             "Bezpieczna odpowiedź"
  end

  test "model catalog respects policy, per-agent restrictions and current user grants", context do
    activate_gateway_policy(context.scope, %{
      "allowed_models" => ["*"],
      "agent_models" => %{context.agent.id => ["qwen3.5:4b"]}
    })

    assert {:ok, %{"data" => [%{"id" => "qwen3.5:4b"}]}} = Gateway.models(context.principal)

    member =
      member_fixture(context.scope, :user, %{
        permissions: ["ai.use"],
        agents: [context.agent.id],
        models: ["catalog-model"]
      })

    assert {:ok, %{"data" => []}} = Gateway.models(member.scope, agent_id: context.agent.id)

    assert {:error, :model_not_allowed} =
             Gateway.chat(member.scope, request(), agent_id: context.agent.id)

    other = organization_fixture()
    other_agent = agent_fixture(other)

    assert {:error, :forbidden} =
             Gateway.chat(context.principal, request(), agent_id: other_agent.id)

    assert {:error, :model_not_allowed} =
             Gateway.chat(context.principal, Map.put(request(), "model", "unknown"))

    refute_received {:backend, _}
  end

  test "revoked identities and stale user grants do not authorize requests", context do
    activate_gateway_policy(context.scope)

    member =
      member_fixture(context.scope, :user, %{
        permissions: ["ai.use"],
        agents: [context.agent.id],
        models: ["qwen3.5:4b"]
      })

    assert {:ok, _} =
             AiControl.Organizations.update_member(context.scope, member.membership.id, %{
               grants: %{permissions: [], agents: [], models: []}
             })

    assert {:error, :forbidden} =
             Gateway.chat(member.scope, request(), agent_id: context.agent.id)

    Repo.update_all(
      from(k in AiControl.ApiKeys.ApiKey, where: k.id == ^context.principal.api_key_id),
      set: [revoked_at: DateTime.utc_now()]
    )

    assert {:error, :forbidden} = Gateway.chat(context.principal, request())
    refute_received {:backend, _}

    rejected =
      Repo.all(from(e in Event, where: e.event_type == "gateway.rejected"))
      |> Enum.filter(&(&1.reason_codes == ["forbidden"]))

    assert Enum.any?(rejected, &(&1.user_id == member.scope.user.id))
    assert Enum.any?(rejected, &(&1.api_key_id == context.principal.api_key_id))
  end

  test "failed input audit prevents even the model metadata call", context do
    activate_gateway_policy(context.scope)

    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT step6_reject_decision CHECK (kind <> 'decision')",
      []
    )

    assert {:error, :audit_unavailable} = Gateway.chat(context.principal, request())
    refute_received {:backend, _}
  end

  test "failed output audit prevents returning generated content", context do
    activate_gateway_policy(context.scope)

    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT step6_reject_output CHECK (stage <> 'output')",
      []
    )

    assert {:error, :audit_unavailable} = Gateway.chat(context.principal, request())
    assert_received {:backend, "/v1/chat/completions"}
  end

  test "missing model and wrong digest never generate", context do
    activate_gateway_policy(context.scope)

    for {models, code} <- [
          {[], :model_unavailable},
          {[%{name: "qwen3.5:4b", digest: String.duplicate("b", 64)}], :model_digest_mismatch}
        ] do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{models: models}))
      assert {:error, ^code} = Gateway.chat(context.principal, request())
    end
  end

  test "a policy activated during generation affects only the next request", context do
    activate_gateway_policy(context.scope)
    {:ok, held} = Policies.current(context.scope)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{
            models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
          })

        _ ->
          activate_gateway_policy(context.scope, %{"allowed_models" => []})
          Req.Test.json(conn, response())
      end
    end)

    id = Ecto.UUID.generate()
    assert {:ok, _} = Gateway.chat(context.principal, request(), request_id: id)
    decisions = Repo.all(from(e in Event, where: e.request_id == ^id and e.kind == :decision))
    assert Enum.all?(decisions, &(&1.policy_version == held.snapshot.version))
    assert {:error, :model_not_allowed} = Gateway.chat(context.principal, request())
  end

  test "input redaction is sent downstream and output redaction is checked on its own fields",
       context do
    guards = disabled_guards() |> Map.put("pii", %{"enabled" => true, "required" => true})
    activate_gateway_policy(context.scope, %{"guards" => guards})

    cfg =
      Config.get()
      |> Keyword.put(:guards, %{"pii" => AiControl.TestGatewayGuard})
      |> Keyword.put(:test_guard, fn fields, _ -> pii_result(fields) end)

    Application.put_env(:ai_control, Config, cfg)
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{
            models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
          })

        _ ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:sent_body, body})
          Req.Test.json(conn, response("Pan Kowalski w Łodzi"))
      end
    end)

    params = put_in(request(), ["messages", Access.at(0), "content"], "Jan Kowalski w Łodzi")
    assert {:ok, output} = Gateway.chat(context.principal, params)
    assert_received {:sent_body, body}
    assert body =~ "[REDACTED]"
    refute body =~ "Kowalski"

    assert get_in(output, ["choices", Access.at(0), "message", "content"]) ==
             "Pan [REDACTED] w Łodzi"

    assert {:error, :redaction_unavailable} =
             Content.redact("Łódź", [%{field_index: 0, start_byte: 1, end_byte: 2}])
  end

  test "semantic checks see only the redacted version and earlier ranges are not reused",
       context do
    guards =
      disabled_guards()
      |> Map.put("pii", %{"enabled" => true, "required" => true})
      |> Map.put("semantic", %{"enabled" => true, "required" => true, "stages" => ["input"]})

    activate_gateway_policy(context.scope, %{"guards" => guards})
    test = self()
    id = Ecto.UUID.generate()

    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:guards, %{
        "pii" => AiControl.TestGatewayGuard,
        "semantic" => AiControl.TestSemanticGuard
      })
      |> Keyword.put(:test_guard, fn fields, _ -> pii_result(fields) end)
      |> Keyword.put(:test_semantic_guard, fn fields, assessment ->
        send(test, {:semantic_fields, fields, assessment.request_id})
        GuardResult.new(%{guard: "semantic", status: :ok})
      end)
    )

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{
            models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
          })

        _ ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:sent_body, Jason.decode!(body)})
          Req.Test.json(conn, response())
      end
    end)

    params = put_in(request(), ["messages", Access.at(0), "content"], "Jan Kowalski w Łodzi")
    assert {:ok, _} = Gateway.chat(context.principal, params, request_id: id)
    assert_received {:semantic_fields, fields, ^id}
    assert "Jan [REDACTED] w Łodzi" in fields
    refute Enum.any?(fields, &String.contains?(&1, "Kowalski"))
    assert_received {:sent_body, sent}
    assert get_in(sent, ["messages", Access.at(0), "content"]) == "Jan [REDACTED] w Łodzi"

    decisions = Repo.all(from(e in Event, where: e.request_id == ^id and e.stage == :input))
    assert Enum.any?(decisions, &(&1.action == :redact && &1.data["evaluated_guards"] != nil))
    assert Enum.any?(decisions, &(&1.action == :allow))
  end

  test "output policy denial withholds generated content and records the output decision",
       context do
    guards =
      disabled_guards()
      |> Map.put("pii", %{"enabled" => true, "required" => true, "stages" => ["output"]})

    activate_gateway_policy(context.scope, %{
      "guards" => guards,
      "rules" => %{"pii" => %{"action" => "block"}}
    })

    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:guards, %{"pii" => AiControl.TestGatewayGuard})
      |> Keyword.put(:test_guard, fn fields, _ -> pii_result(fields) end)
    )

    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{
            models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
          })

        _ ->
          send(test, :generated)
          Req.Test.json(conn, response("Pan Kowalski w Łodzi"))
      end
    end)

    id = Ecto.UUID.generate()
    assert {:error, :policy_blocked} = Gateway.chat(context.principal, request(), request_id: id)
    assert_received :generated
    events = Repo.all(from(e in Event, where: e.request_id == ^id))

    assert Enum.any?(
             events,
             &(&1.kind == :decision && &1.stage == :output && &1.action == :block)
           )

    assert Enum.any?(events, &(&1.event_type == "gateway.rejected"))
    refute events |> Enum.map(&Map.take(&1, Event.fields())) |> Jason.encode!() =~ "Kowalski"
  end

  test "invalid guard data never reaches the backend", context do
    guards = disabled_guards() |> Map.put("pii", %{"enabled" => true, "required" => true})

    activate_gateway_policy(context.scope, %{
      "guards" => guards,
      "rules" => %{"pii" => %{"action" => "block"}}
    })

    for callback <- [fn _, _ -> {:ok, %{garbage: "secret"}} end, fn _, _ -> raise "secret" end] do
      Application.put_env(
        :ai_control,
        Config,
        Config.get()
        |> Keyword.put(:guards, %{"pii" => AiControl.TestGatewayGuard})
        |> Keyword.put(:test_guard, callback)
      )

      assert {:error, :guard_unavailable} = Gateway.chat(context.principal, request())
    end

    refute_received {:backend, _}
  end

  test "agent keys share one ingress counter and overload carries retry time", context do
    activate_gateway_policy(context.scope)
    Application.put_env(:ai_control, Config, Keyword.put(Config.get(), :requests_per_minute, 2))
    other_key = principal_fixture(context.scope, context.agent)
    assert {:ok, _} = Gateway.models(context.principal)
    assert {:ok, _} = Gateway.models(other_key)
    assert {:error, {:rate_limited, retry}} = Gateway.models(other_key)
    assert retry in 1..60
  end

  defp disabled_guards,
    do: Map.new(Configuration.guards(), &{&1, %{"enabled" => false, "required" => false}})

  defp pii_result(fields) do
    detections =
      fields
      |> Enum.with_index()
      |> Enum.flat_map(fn {text, index} ->
        case :binary.match(text, "Kowalski") do
          {first, len} ->
            {:ok, detection} =
              Detection.new(%{
                guard: "pii",
                category: "pii",
                rule_id: "pii.test",
                confidence: 1,
                location: %{field_index: index, start_byte: first, end_byte: first + len}
              })

            [detection]

          :nomatch ->
            []
        end
      end)

    GuardResult.new(%{guard: "pii", status: :ok, detections: detections})
  end
end
