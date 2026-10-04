defmodule AiControl.DashboardTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures
  import AiControl.SecurityFixtures

  alias AiControl.{Audit, Budgets, Dashboard, Organizations, Policies, Security}
  alias AiControl.Audit.{Filters, Serializer}
  alias AiControl.Gateway.Config

  test "committed tool audit remains readable without counting dispatch as a terminal request" do
    context = AiControl.ToolsFixtures.tool_fixture()

    evidence = %{
      execution_id: Ecto.UUID.generate(),
      workflow_id: context.workflow,
      execution_status: "dispatching",
      tool: "file.read",
      charged: true
    }

    assert {:ok, _} =
             Audit.record_tool(
               context.principal,
               Ecto.UUID.generate(),
               "tool.dispatching",
               "dispatching",
               0,
               nil,
               evidence
             )

    {:ok, filters} = Filters.parse()
    assert {:ok, %{total: 0}} = Dashboard.activity(context.scope, filters)
    assert {:ok, result} = AiControl.ToolsFixtures.tool_call(context)
    {:ok, filters} = Filters.parse()

    assert {:ok, %{total: 1, counts: %{"allow" => 1}}} =
             Dashboard.activity(context.scope, filters)

    assert {:ok, events} = Audit.list_events(context.scope)
    event = Enum.find(events, &(&1.event_type == "tool.completed"))
    serialized = Serializer.event(event)
    assert serialized.data["tool_execution"]["execution_id"] == result.execution_id
    assert serialized.data["tool_execution"]["execution_status"] == "completed"
    assert serialized.data["tool_execution"]["charged"]

    malicious = Map.update!(event.data, "tool_execution", &Map.put(&1, "arguments", "private"))
    assert Serializer.data(malicious) == serialized.data
    refute Jason.encode!(serialized) =~ "Zażółć gęślą jaźń"

    assert {:ok, _} =
             Audit.record_tool(
               context.principal,
               Ecto.UUID.generate(),
               "tool.failed",
               "tool_upstream_unavailable",
               0,
               nil,
               %{evidence | execution_status: "failed"}
             )

    {:ok, filters} = Filters.parse()
    assert {:ok, report} = Dashboard.activity(context.scope, filters)
    assert report.total == 2
    assert report.counts["service_error"] == 1
    assert report.errors == [%{id: "tool_upstream_unavailable", count: 1}]
  end

  test "requests and detections count once across phase evidence and percentiles use measured samples" do
    scope = organization_fixture()
    policy = policy_fixture()
    request = Ecto.UUID.generate()

    for _ <- 1..2 do
      {:ok, context} = AiControl.Gateway.context(scope, policy, request, :input)

      assessment =
        assessment_fixture(context, [result_fixture(%{detections: [detection_fixture()]})])

      assert {:ok, %{action: :redact}} = Security.evaluate_and_audit(context, assessment, policy)
    end

    assert {:ok, _} =
             Audit.record_gateway(scope, request, "completed", 100, nil, :output, nil, %{
               operation: "chat",
               timings: %{"request" => 100, "upstream" => 80}
             })

    for duration <- [200, 300, 400] do
      assert {:ok, _} =
               Audit.record_gateway(
                 scope,
                 Ecto.UUID.generate(),
                 "completed",
                 duration,
                 nil,
                 :output,
                 nil,
                 %{operation: "chat", timings: %{"request" => duration}}
               )
    end

    assert {:ok, _} =
             Audit.record_gateway(scope, Ecto.UUID.generate(), "request_budget_exceeded", 0)

    assert {:ok, _} = Audit.record_gateway(scope, Ecto.UUID.generate(), "upstream_timeout", 0)
    other = organization_fixture()
    assert {:ok, _} = Audit.record_gateway(other, Ecto.UUID.generate(), "completed", 99_999)
    {:ok, filters} = Filters.parse()
    assert {:ok, report} = Dashboard.activity(scope, filters)
    assert report.total == 6
    assert report.counts["redact"] == 1
    assert report.counts["allow"] == 3
    assert report.counts["budget_denied"] == 1
    assert report.counts["service_error"] == 1
    assert [%{count: 1}] = report.detections
    assert %{p50: 200, p95: 400, count: 4} = Enum.find(report.latencies, &(&1.id == "request"))
    assert %{count: 1, p95: 80} = Enum.find(report.latencies, &(&1.id == "upstream"))
  end

  test "historical records have no invented timing samples and capability projections stay independent" do
    scope = organization_fixture()
    reader = member_fixture(scope, :user, %{permissions: ["budgets.read", "signatures.read"]})
    {:ok, filters} = Filters.parse()
    assert {:error, :forbidden} = Dashboard.activity(reader.scope, filters)
    assert {:error, :forbidden} = Policies.current(reader.scope)
    assert {:ok, budget} = Dashboard.budgets(reader.scope)
    assert budget.agents == []
    assert budget.bucket.tokens == 0
    refute Map.has_key?(budget.policy, :guards)
    assert {:ok, catalog} = Dashboard.signatures(reader.scope)
    assert length(catalog.signatures) == 4
    refute Map.has_key?(catalog.policy, :limits)
    assert {:ok, _} = Audit.record_gateway(scope, Ecto.UUID.generate(), "completed", 0)
    assert {:ok, %{latencies: []}} = Dashboard.activity(scope, filters)
    assert {:ok, _} = Organizations.remove_member(scope, reader.membership.id)
    assert {:error, :forbidden} = Dashboard.signatures(reader.scope)
    assert {:error, :forbidden} = Dashboard.budgets(reader.scope)
  end

  test "budgets show durable held and settled tokens across UTC hours and assigned agents only" do
    old = Config.get()
    Application.put_env(:ai_control, Config, Keyword.put(old, :prices, %{}))
    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)

    scope = organization_fixture()
    agent = agent_fixture(scope)
    hidden = agent_fixture(scope)
    principal = principal_fixture(scope, agent)

    activate_gateway_policy(scope, %{
      "budgets" => %{"organization" => %{"tokens_per_hour" => 500}}
    })

    {:ok, policy, _} = Policies.snapshot_for_models(principal, nil)
    now = ~U[2026-10-04 00:59:59Z]

    {:ok, receipt} =
      Budgets.admit(principal, nil, "deepseek-flash", policy, Ecto.UUID.generate(), now)

    {:ok, receipt} = Budgets.reserve(receipt, 10, 20)
    reader = member_fixture(scope, :user, %{permissions: ["budgets.read"], agents: [agent.id]})
    assert {:ok, held} = Dashboard.budgets(reader.scope, now)
    assert held.bucket.reserved == 30
    assert [%{id: id}] = held.agents
    assert id == agent.id
    refute Enum.any?(held.agents, &(&1.id == hidden.id))
    {:ok, receipt} = Budgets.dispatch(receipt)

    {:ok, _} =
      Budgets.settle(receipt, %{
        "prompt_tokens" => 10,
        "completion_tokens" => 5,
        "total_tokens" => 15
      })

    assert {:ok, settled} = Dashboard.budgets(reader.scope, now)
    assert settled.bucket.tokens == 15
    assert settled.bucket.reserved == 0
    assert [%{not_configured: 1, currency: nil}] = settled.costs
    assert {:ok, next} = Dashboard.budgets(reader.scope, DateTime.add(now, 1))
    assert next.bucket.tokens == 0
    assert next.bucket.requests == 0
  end

  test "cost totals keep currencies, exact zero and unavailable reservations distinct" do
    scope = organization_fixture()
    agent = agent_fixture(scope)
    principal = principal_fixture(scope, agent)
    activate_gateway_policy(scope)
    {:ok, policy, _} = Policies.snapshot_for_models(principal, nil)
    now = ~U[2026-10-04 02:30:00Z]
    old = Config.get()
    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)

    for {currency, rate} <- [{"USD", "0"}, {"EUR", "3"}] do
      price = %{"currency" => currency, "input_per_million" => rate, "output_per_million" => rate}

      Application.put_env(
        :ai_control,
        Config,
        Keyword.put(old, :prices, %{"deepseek-flash" => price})
      )

      {:ok, receipt} =
        Budgets.admit(principal, nil, "deepseek-flash", policy, Ecto.UUID.generate(), now)

      {:ok, receipt} = Budgets.dispatch(receipt)

      {:ok, _} =
        Budgets.settle(receipt, %{
          "prompt_tokens" => 10,
          "completion_tokens" => 5,
          "total_tokens" => 15
        })
    end

    {:ok, uncertain} =
      Budgets.admit(principal, nil, "deepseek-flash", policy, Ecto.UUID.generate(), now)

    {:ok, uncertain} = Budgets.dispatch(uncertain)
    {:ok, _} = Budgets.abandon(uncertain)
    assert {:ok, report} = Dashboard.budgets(scope, now)
    assert report.statuses["uncertain"] == 1
    assert report.bucket.unbounded == 1
    assert Decimal.equal?(Enum.find(report.costs, &(&1.currency == "USD")).cost, Decimal.new(0))
    euro = Enum.find(report.costs, &(&1.currency == "EUR"))
    assert Decimal.equal?(euro.cost, Decimal.new("0.000045"))
    assert euro.unavailable == 1
  end
end
