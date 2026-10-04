defmodule AiControl.Guards.GraniteEnforcementTest do
  use AiControl.DataCase, async: false

  import AiControl.ToolsFixtures
  import AiControl.WorkflowsFixtures

  alias AiControl.Audit.{Event, Serializer}
  alias AiControl.Gateway.{Config, Stages}
  alias AiControl.Guards.Granite
  alias AiControl.Guards.Granite.Model
  alias AiControl.Guards.Granite.Plan
  alias AiControl.{Policies, Repo, Tools}
  alias AiControl.Policies.{Configuration, ConfigurationV6}
  alias AiControl.Policy.Snapshot
  alias AiControl.Security.{Detection, GuardResult}
  alias AiControl.Tools.Sandbox
  alias AiControl.Tools.ToolRequest
  alias AiControl.Workflows

  setup do
    old = Application.fetch_env!(:ai_control, Config)
    parent = self()

    Application.put_env(
      :ai_control,
      Config,
      old
      |> Keyword.merge(
        guards: %{"granite" => Granite},
        granite_provider: AiControl.TestGraniteProvider,
        test_granite: fn prompt, _ ->
          send(parent, {:judge, prompt})
          {:ok, "no", %{"prompt_tokens" => 40, "completion_tokens" => 6, "total_tokens" => 46}}
        end
      )
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    c = tool_fixture()

    activate_workflows(c.scope, %{}, %{
      "schema_version" => 6,
      "granite" => Map.put(ConfigurationV6.defaults(), "enabled", true)
    })

    reference = run_reference_fixture(c.principal)
    {:ok, policy, _} = Policies.snapshot_for_models(c.principal, nil)
    Map.merge(c, %{reference: reference, policy: policy})
  end

  test "ordinary request skips Granite with historical evidence", c do
    params = AiControl.GatewayFixtures.request()

    assert {:ok, ^params} =
             Stages.evaluate(params, c.principal, c.policy, Ecto.UUID.generate(), :input,
               run_context: c.reference
             )

    refute_received {:judge, _}

    event =
      Repo.one!(
        from e in Event,
          where: e.event_type == "security.decision",
          order_by: [desc: e.occurred_at],
          limit: 1
      )

    data = Serializer.data(event.data)

    assert [%{"guard" => "granite", "status" => "skipped", "evidence" => %{"digest" => digest}}] =
             data["guards"]

    assert digest == Model.digest()
  end

  test "negative tool alignment blocks before effect; idempotent rejection does not charge twice",
       c do
    key = Ecto.UUID.generate()

    action = %{
      "tool" => "file.write",
      "arguments" => %{"path" => "copy.txt", "content" => "PRIVATE ARGUMENT"}
    }

    assert {:error, :policy_blocked} =
             Tools.execute(c.principal, action, run_context: c.reference, idempotency_key: key)

    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
    assert_received {:judge, prompt}
    assert prompt =~ "Synthetic integration execution"
    assert prompt =~ "PRIVATE ARGUMENT"

    assert {:error, _} =
             Tools.execute(c.principal, action, run_context: c.reference, idempotency_key: key)

    refute_received {:judge, _}
    events = Repo.all(from e in Event, where: e.event_type == "security.decision")
    exported = Enum.map_join(events, &Jason.encode!(Serializer.event(&1)))
    refute exported =~ "PRIVATE ARGUMENT"
    refute exported =~ "Synthetic integration execution"
    refute exported =~ "The proposed tool action"
    assert exported =~ "high_risk_tool"
    assert exported =~ "tool_alignment.v1"
    assert exported =~ "block_on"
  end

  test "yes polarity can block and missing selected adapter fails closed", c do
    settings =
      put_in(c.policy.settings, ["granite", "criteria", "tool_alignment.v1", "block_on"], "yes")

    {:ok, config} = Configuration.validate(settings)

    {:ok, policy} =
      Snapshot.from_version(%{id: Ecto.UUID.generate(), checksum: nil, settings: config.settings})

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :test_granite, fn _, _ ->
        {:ok, "yes", %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}}
      end)
    )

    action = %{
      "tool" => "file.write",
      "arguments" => %{"path" => "copy.txt", "content" => "safe"}
    }

    {:ok, request} = ToolRequest.new(c.principal, action, policy)

    opts = [
      run_context: c.reference,
      tool_request: request,
      content_adapter: AiControl.Tools.Content
    ]

    assert {:error, :policy_blocked} =
             Stages.evaluate(action, c.principal, policy, Ecto.UUID.generate(), :input, opts)

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :test_granite, fn _, _ -> {:error, :unavailable} end)
    )

    assert {:error, :guard_unavailable} =
             Stages.evaluate(action, c.principal, policy, Ecto.UUID.generate(), :input, opts)
  end

  test "untrusted workflow reference cannot supply a judging goal", c do
    assert {:error, _} =
             Workflows.judging_context(c.principal, c.policy, %{
               run_id: Ecto.UUID.generate(),
               participant_id: c.reference.participant_id,
               goal: "client supplied"
             })

    refute_received {:judge, _}
  end

  test "earlier findings, Qwen labels and Prompt Guard threshold select suspicious input", c do
    settings = c.policy.settings["granite"]
    params = AiControl.GatewayFixtures.request()
    options = [granite_identity: c.principal, run_context: c.reference, granite_value: params]

    for {signal, expected} <- [
          {[granite_findings: true], "earlier_findings"},
          {[granite_previous: [%{evidence: %{"windows" => [%{"severity" => "Unsafe"}]}}]],
           "qwen_label"},
          {[granite_previous: [%{evidence: %{"windows" => [%{"severity" => "Controversial"}]}}]],
           "qwen_label"},
          {[
             granite_previous: [
               %{
                 evidence: %{"signal_kind" => "classifier_score"},
                 signals: %{"injection_score" => settings["suspicious_threshold"]}
               }
             ]
           ], "prompt_guard_score"}
        ] do
      checks =
        Plan.build(["redacted text"], %{stage: :input}, c.policy, Keyword.merge(options, signal))

      selected = Enum.filter(checks, &Plan.selected?/1)
      assert [%{evidence: %{"trigger" => ^expected}, target: ["redacted text"]}] = selected

      assert {:ok, result} =
               Granite.assess(
                 [],
                 %{stage: :input},
                 c.policy,
                 Config.get() |> Keyword.merge(options) |> Keyword.put(:granite_plan, checks)
               )

      assert result.status == :ok
      assert_received {:judge, _}
    end

    previous = [
      %{evidence: %{"signal_kind" => "classifier_score"}, signals: %{"injection_score" => 0.249}}
    ]

    checks =
      Plan.build(
        [],
        %{stage: :input},
        c.policy,
        Keyword.put(options, :granite_previous, previous)
      )

    refute Enum.any?(checks, &Plan.selected?/1)
  end

  test "privileged selectors inspect an authorized read without granting new access", c do
    settings =
      c.policy.settings
      |> put_in(["granite", "privileged_resources", "paths"], ["report.txt", "ungranted.txt"])

    policy = snapshot(settings)
    action = %{"tool" => "file.read", "arguments" => %{"path" => "report.txt"}}
    {:ok, request} = ToolRequest.new(c.principal, action, policy)

    opts = [
      run_context: c.reference,
      tool_request: request,
      content_adapter: AiControl.Tools.Content
    ]

    assert {:error, :policy_blocked} =
             Stages.evaluate(action, c.principal, policy, Ecto.UUID.generate(), :input, opts)

    assert_received {:judge, prompt}
    assert prompt =~ "permitted_resources"
    assert prompt =~ "report.txt"

    activate_workflows(c.scope, %{}, %{"schema_version" => 6, "granite" => settings["granite"]})

    assert {:error, :tool_resource_not_allowed} =
             Tools.execute(
               c.principal,
               put_in(action, ["arguments", "path"], "ungranted.txt"),
               run_context: c.reference,
               idempotency_key: Ecto.UUID.generate()
             )

    refute_received {:judge, _}
  end

  test "proposed tool calls are checked before they can reach the client", c do
    response =
      AiControl.GatewayFixtures.response()
      |> put_in(["choices", Access.at(0), "message", "tool_calls"], [
        %{
          "id" => "call-1",
          "type" => "function",
          "function" => %{
            "name" => "file.write",
            "arguments" => Jason.encode!(%{"path" => "copy.txt", "content" => "proposed only"})
          }
        }
      ])

    assert {:error, :policy_blocked} =
             Stages.evaluate(response, c.principal, c.policy, Ecto.UUID.generate(), :output,
               run_context: c.reference
             )

    assert_received {:judge, prompt}
    assert prompt =~ "proposed only"
    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end

  test "a deterministic refusal stops the pipeline before Granite", c do
    {:ok, detection} =
      Detection.new(%{guard: "secret", category: "secret", rule_id: "secret.test", confidence: 1})

    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:guards, %{"granite" => Granite, "secret" => AiControl.TestGatewayGuard})
      |> Keyword.put(:test_guard, fn _, _ ->
        GuardResult.new(%{guard: "secret", status: :ok, detections: [detection]})
      end)
    )

    settings =
      put_in(c.policy.settings, ["guards", "secret"], %{
        "enabled" => true,
        "required" => true,
        "stages" => ["input", "output"]
      })

    assert {:error, :policy_blocked} =
             Stages.evaluate(
               AiControl.GatewayFixtures.request(),
               c.principal,
               snapshot(settings),
               Ecto.UUID.generate(),
               :input,
               run_context: c.reference
             )

    refute_received {:judge, _}
  end

  test "a configured adapter cannot silently omit a selected check", c do
    checks =
      Plan.build([], %{stage: :input}, c.policy,
        granite_value: AiControl.GatewayFixtures.request()
      )

    result = Granite.skipped(checks)

    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:guards, %{"granite" => AiControl.TestGatewayGuard})
      |> Keyword.put(:test_guard, fn _, _ -> {:ok, result} end)
    )

    action = %{
      "tool" => "file.write",
      "arguments" => %{"path" => "copy.txt", "content" => "safe"}
    }

    assert {:error, :guard_unavailable} =
             Tools.execute(c.principal, action,
               run_context: c.reference,
               idempotency_key: Ecto.UUID.generate()
             )

    refute Map.has_key?(Sandbox.inspect_state(c.sandbox).files, "copy.txt")
  end

  defp snapshot(settings) do
    {:ok, config} = Configuration.validate(settings)

    {:ok, policy} =
      Snapshot.from_version(%{id: Ecto.UUID.generate(), checksum: nil, settings: config.settings})

    policy
  end
end
