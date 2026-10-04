defmodule AiControl.Gateway.KnowledgeTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.KnowledgeFixtures
  import AiControl.OrganizationsFixtures
  import AiControl.WorkflowsFixtures

  alias AiControl.{Gateway, Knowledge, Repo}
  alias AiControl.Gateway.Config
  alias AiControl.Policies.Configuration
  alias AiControl.Security.{Detection, GuardResult}
  alias Ecto.Adapters.SQL

  setup do
    old = Application.fetch_env!(:ai_control, Config)

    Application.put_env(
      :ai_control,
      Config,
      old
      |> Keyword.put(:requests_per_minute, 10_000)
      |> Keyword.put(:http_plug, {Req.Test, __MODULE__})
      |> Keyword.put(:tokenizer, AiControl.TestBudgetTokenizer)
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    scope = organization_fixture()
    agent = agent_fixture(scope)
    principal = principal_fixture(scope, agent)

    activate_knowledge_policy(scope, %{
      "budgets" => %{"organization" => %{"tokens_per_hour" => 10_000}}
    })

    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{
            models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
          })

        "/api/version" ->
          Req.Test.json(conn, %{version: "0.35.1"})

        _ ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          params = Jason.decode!(body)

          if params["_debug_render_only"] do
            send(parent, {:rendered, params})

            Req.Test.json(conn, %{
              _debug_info: %{rendered_template: Jason.encode!(params["messages"])}
            })
          else
            send(parent, {:generated, params})
            Req.Test.json(conn, response())
          end
      end
    end)

    %{scope: scope, agent: agent, principal: principal}
  end

  defp rag, do: request() |> Map.put("context", %{"query" => "support"})

  test "retrieved sources are data, context is stripped, and augmented prompt is tokenized", c do
    document = document_fixture(c.scope, c.agent)
    parent = self()

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :test_tokenizer, fn _, prompt ->
        send(parent, {:counted, prompt})
        {:ok, 40}
      end)
    )

    assert {:ok, _} = chat(c.principal, rag())
    assert_received {:generated, params}
    refute Map.has_key?(params, "context")

    assert [
             %{"role" => "user", "name" => "retrieved_context", "content" => context},
             %{"role" => "user"}
           ] = params["messages"]

    assert context =~ document["id"]
    assert context =~ "Support is available"
    assert_received {:counted, prompt}
    assert prompt =~ "Support is available"

    reservation =
      Repo.get_by!(AiControl.Budgets.Reservation, organization_id: c.scope.organization.id)

    assert reservation.input_tokens == 40
  end

  test "legacy chats work but RAG requires an enabled policy and final user message", c do
    activate_gateway_policy(c.scope)
    assert {:ok, _} = chat(c.principal, request())
    assert_received {:generated, _}
    assert {:error, :knowledge_disabled} = chat(c.principal, rag())
    refute_received {:generated, _}
    activate_knowledge_policy(c.scope)

    assert {:error, :input_too_large} =
             chat(
               c.principal,
               Map.put(rag(), "context", %{"query" => String.duplicate("x", 2049)})
             )

    assert {:error, :invalid_request} =
             chat(
               c.principal,
               Map.put(rag(), "messages", [
                 %{"role" => "assistant", "content" => "Previous output"}
               ])
             )
  end

  test "indirect injection in stored document or memory blocks before the model", c do
    for kind <- ~w(document memory) do
      document_fixture(c.scope, c.agent, %{
        "kind" => kind,
        "content" => "support MALICIOUS_INSTRUCTION"
      })
    end

    enable_guard(
      c.scope,
      "semantic",
      fn fields -> Enum.any?(fields, &String.contains?(&1, "MALICIOUS_INSTRUCTION")) end,
      "prompt_injection"
    )

    assert {:error, :policy_blocked} = chat(c.principal, rag())
    refute_received {:generated, _}
    refute_received {:rendered, _}
  end

  test "whole assembled context is scanned after separately checked sources", c do
    document_fixture(c.scope, c.agent, %{"content" => "support PART_ONE"})
    document_fixture(c.scope, c.agent, %{"content" => "support PART_TWO"})

    enable_guard(
      c.scope,
      "secret",
      fn fields ->
        Enum.any?(fields, &(String.contains?(&1, "PART_ONE") && String.contains?(&1, "PART_TWO")))
      end,
      "secret"
    )

    assert {:error, :policy_blocked} = chat(c.principal, rag())
    refute_received {:generated, _}
  end

  test "source revision is checked again after tokenization", c do
    document = document_fixture(c.scope, c.agent)
    parent = self()

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :test_tokenizer, fn _, _ ->
        send(parent, {:waiting, self()})

        receive do
          :continue -> {:ok, 40}
        end
      end)
    )

    supervisor = start_supervised!(Task.Supervisor)
    reference = run_reference_fixture(c.principal)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Gateway.chat(c.principal, rag(), run_context: reference)
      end)

    assert_receive {:waiting, worker}

    Repo.update_all(
      from(r in AiControl.Knowledge.Resource, where: r.id == ^document["id"]),
      [inc: [revision: 1]],
      log: false
    )

    send(worker, :continue)
    assert {:error, :knowledge_conflict} = Task.await(task)
    refute_received {:generated, _}
  end

  test "suspension during scan prevents returning stored content", c do
    document = document_fixture(c.scope, c.agent)
    parent = self()

    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:guards, %{"pii" => AiControl.TestGatewayGuard})
      |> Keyword.put(:test_guard, fn _, _ ->
        send(parent, {:waiting, self()})

        receive do
          :continue -> GuardResult.new(%{guard: "pii", status: :ok})
        end
      end)
    )

    activate_knowledge_policy(c.scope, %{
      "guards" => %{
        "pii" => %{"enabled" => true, "required" => true},
        "secret" => %{"enabled" => false, "required" => false},
        "signatures" => %{"enabled" => false, "required" => false},
        "semantic" => %{"enabled" => false, "required" => false},
        "ner" => %{"enabled" => false, "required" => false}
      }
    })

    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Knowledge.get(c.principal, document["id"])
      end)

    assert_receive {:waiting, worker}

    Repo.update_all(
      from(a in AiControl.Agents.Agent, where: a.id == ^c.agent.id),
      [set: [status: :suspended]],
      log: false
    )

    send(worker, :continue)
    assert {:error, :forbidden} = Task.await(task)
  end

  test "required guard failure and input audit failure do not generate", c do
    document_fixture(c.scope, c.agent)

    activate_knowledge_policy(c.scope, %{
      "guards" => %{"ner" => %{"enabled" => true, "required" => true}}
    })

    assert {:error, :guard_unavailable} = chat(c.principal, rag())
    refute_received {:generated, _}
    activate_knowledge_policy(c.scope)

    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT reject_rag_audit CHECK (kind <> 'decision') NOT VALID",
      []
    )

    assert {:error, :audit_unavailable} = chat(c.principal, rag())
    refute_received {:generated, _}
  end

  defp enable_guard(scope, guard, predicate, category) do
    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:guards, %{guard => AiControl.TestGatewayGuard})
      |> Keyword.put(:test_guard, fn fields, _ ->
        detections =
          if predicate.(fields) do
            {:ok, detection} =
              Detection.new(%{
                guard: guard,
                category: category,
                rule_id: "knowledge.test",
                confidence: 1
              })

            [detection]
          else
            []
          end

        GuardResult.new(%{guard: guard, status: :ok, detections: detections})
      end)
    )

    guards =
      Map.new(
        Configuration.guards(5),
        &{&1, %{"enabled" => false, "required" => false}}
      )
      |> Map.put(guard, %{"enabled" => true, "required" => true})

    activate_knowledge_policy(scope, %{"guards" => guards})
  end

  defp chat(identity, params) do
    {:ok, policy, _} = AiControl.Policies.snapshot_for_models(identity, nil)

    opts =
      if policy.settings["schema_version"] == 5,
        do: [run_context: run_reference_fixture(identity)],
        else: []

    Gateway.chat(identity, params, opts)
  end
end
