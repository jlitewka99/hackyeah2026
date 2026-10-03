defmodule AiControl.Budgets.AccountingTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.{Budgets, Policies, Repo}
  alias AiControl.Budgets.{Bucket, Cache, Reservation}
  alias AiControl.Gateway.Config
  alias Ecto.Adapters.SQL

  setup do
    scope = organization_fixture()
    agent = agent_fixture(scope)
    principal = principal_fixture(scope, agent)
    %{scope: scope, agent: agent, principal: principal}
  end

  defp policy(context, limits \\ %{}) do
    activate_gateway_policy(context.scope, %{"budgets" => limits})
    {:ok, snapshot, _} = Policies.snapshot_for_models(context.principal, nil)
    snapshot
  end

  defp admit(context, snapshot, now \\ DateTime.utc_now()) do
    {:ok, receipt} =
      Budgets.admit(context.principal, nil, "qwen3.5:4b", snapshot, Ecto.UUID.generate(), now)

    receipt
  end

  defp usage(input, output),
    do: %{
      "prompt_tokens" => input,
      "completion_tokens" => output,
      "total_tokens" => input + output
    }

  defp bucket(context),
    do:
      Repo.get_by!(Bucket, organization_id: context.scope.organization.id, level: "organization")

  test "5000 budget holds 4000 and returns exactly 1800 after usage 2200", context do
    snapshot = policy(context, %{"organization" => %{"tokens_per_hour" => 5000}})
    first = admit(context, snapshot)
    second = admit(context, snapshot)
    assert {:ok, held} = Budgets.reserve(first, 2000, 2000)
    assert {:error, {:token_budget_exceeded, retry}} = Budgets.reserve(second, 2000, 2000)
    assert retry in 1..3600
    assert bucket(context).reserved == 4000
    assert {:ok, sent} = Budgets.dispatch(held)
    assert {:ok, settled} = Budgets.settle(sent, usage(2000, 200))
    assert settled.status == "settled"
    assert bucket(context).tokens == 2200
    assert bucket(context).reserved == 0
    assert {:ok, _} = Budgets.settle(sent, usage(2000, 200))
    assert {:error, :budget_conflict} = Budgets.settle(sent, usage(2000, 201))
    assert bucket(context).tokens == 2200
    assert {:error, :budget_conflict} = Budgets.dispatch(sent)
  end

  test "agent denial rolls back the organization counter and zero denies admission", context do
    snapshot =
      policy(context, %{
        "organization" => %{"requests_per_hour" => 5},
        "agent" => %{"requests_per_hour" => 1}
      })

    admit(context, snapshot)

    assert {:error, {:request_budget_exceeded, _}} =
             Budgets.admit(context.principal, nil, "qwen3.5:4b", snapshot, Ecto.UUID.generate())

    assert bucket(context).requests == 1
    zero = policy(context, %{"organization" => %{"requests_per_hour" => 0}})

    assert {:error, {:request_budget_exceeded, _}} =
             Budgets.admit(context.principal, nil, "qwen3.5:4b", zero, Ecto.UUID.generate())

    assert bucket(context).requests == 1
  end

  test "restart cleanup releases unsent tokens and retains potentially generated tokens",
       context do
    snapshot = policy(context, %{"organization" => %{"tokens_per_hour" => 5000}})
    first = admit(context, snapshot)
    second = admit(context, snapshot)
    {:ok, first} = Budgets.reserve(first, 100, 100)
    {:ok, second} = Budgets.reserve(second, 1000, 1000)
    {:ok, second} = Budgets.dispatch(second)
    assert :ok = Budgets.recover()
    assert Repo.get!(Reservation, first.id).status == "released"
    assert Repo.get!(Reservation, second.id).status == "uncertain"
    assert bucket(context).reserved == 2000
    assert :ok = Cache.clear()
    assert {:ok, state} = Budgets.state(context.scope)
    assert state.reserved == 2000
    assert {:ok, _} = Budgets.abandon(second)
    assert bucket(context).reserved == 2000
  end

  test "usage overrun is recorded in full and lowered policies do not reset accounting",
       context do
    snapshot = policy(context, %{"organization" => %{"tokens_per_hour" => 3000}})
    receipt = admit(context, snapshot)
    {:ok, receipt} = Budgets.reserve(receipt, 500, 500)
    {:ok, receipt} = Budgets.dispatch(receipt)
    assert {:ok, %{overrun: true}} = Budgets.settle(receipt, usage(500, 4000))
    lowered = policy(context, %{"organization" => %{"tokens_per_hour" => 1000}})
    new = admit(context, lowered)
    assert {:error, {:token_budget_exceeded, _}} = Budgets.reserve(new, 1, 1)
    assert bucket(context).tokens == 4500
  end

  test "completion remains in its original UTC hour across a boundary", context do
    snapshot = policy(context, %{"organization" => %{"tokens_per_hour" => 5000}})
    receipt = admit(context, snapshot, ~U[2026-10-03 23:59:59Z])
    {:ok, receipt} = Budgets.reserve(receipt, 200, 200)
    {:ok, receipt} = Budgets.dispatch(receipt)
    assert {:ok, _} = Budgets.settle(receipt, usage(200, 10))
    admit(context, snapshot, ~U[2026-10-04 00:00:00Z])
    assert {:ok, old} = Budgets.state(context.scope, nil, ~U[2026-10-03 23:59:59Z])
    assert old.tokens == 210
    assert {:ok, new} = Budgets.state(context.scope, nil, ~U[2026-10-04 00:00:00Z])
    assert new.tokens == 0
    assert new.requests == 1
  end

  test "unbounded uncertain usage blocks a newly configured token budget until audited reconciliation",
       context do
    snapshot = policy(context)
    receipt = admit(context, snapshot)
    {:ok, receipt} = Budgets.dispatch(receipt)
    {:ok, _} = Budgets.abandon(receipt)
    hard = policy(context, %{"organization" => %{"tokens_per_hour" => 5000}})
    new = admit(context, hard)
    assert {:error, {:token_budget_exceeded, _}} = Budgets.reserve(new, 1, 1)
    assert {:error, :forbidden} = Budgets.reconcile(organization_fixture(), receipt.id, :not_sent)
    assert {:ok, _} = Budgets.reconcile(context.scope, receipt.id, usage(20, 20))
    assert bucket(context).unbounded == 0
    assert {:ok, _} = Budgets.reserve(new, 1, 1)

    assert Repo.exists?(
             from(e in AiControl.Audit.Event,
               where: e.target_id == ^receipt.id and e.event_type == "budget.reconciled"
             )
           )
  end

  test "price snapshot and exact decimal cost survive operator price changes", context do
    old = Application.fetch_env!(:ai_control, Config)
    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    price = %{"currency" => "USD", "input_per_million" => "2.50", "output_per_million" => "10.00"}
    Application.put_env(:ai_control, Config, Keyword.put(old, :prices, %{"qwen3.5:4b" => price}))
    snapshot = policy(context)
    receipt = admit(context, snapshot)
    Application.put_env(:ai_control, Config, Keyword.put(old, :prices, %{}))
    {:ok, receipt} = Budgets.dispatch(receipt)
    assert {:ok, settled} = Budgets.settle(receipt, usage(1000, 100))
    assert Decimal.equal?(settled.cost, Decimal.new("0.0035"))
    assert settled.price == price
    assert Budgets.evidence(settled).currency == "USD"
  end

  test "tool executions are deduplicated and the workflow is bound to its tenant and agent",
       context do
    snapshot = policy(context, %{"workflow" => %{"tool_calls" => 1}})
    workflow = Ecto.UUID.generate()
    execution = Ecto.UUID.generate()

    assert {:ok, first} =
             Budgets.consume_tool_call(context.principal, nil, snapshot, workflow, execution)

    assert {:ok, again} =
             Budgets.consume_tool_call(context.principal, nil, snapshot, workflow, execution)

    assert first.id == again.id

    assert {:error, :tool_budget_exceeded} =
             Budgets.consume_tool_call(
               context.principal,
               nil,
               snapshot,
               workflow,
               Ecto.UUID.generate()
             )

    other = agent_fixture(context.scope)
    other_principal = principal_fixture(context.scope, other)

    assert {:error, :forbidden} =
             Budgets.consume_tool_call(other_principal, nil, snapshot, workflow, execution)
  end

  test "read permissions and agent grants are refreshed", context do
    snapshot = policy(context)
    admit(context, snapshot)
    user = member_fixture(context.scope, :user, %{permissions: [], agents: [], models: []})
    assert {:error, :forbidden} = Budgets.state(user.scope)

    assert {:error, :forbidden} =
             Budgets.state(context.scope, agent_fixture(organization_fixture()).id)
  end

  test "reconciliation audit failure rolls back the refund", context do
    snapshot = policy(context, %{"organization" => %{"tokens_per_hour" => 5000}})
    receipt = admit(context, snapshot)
    {:ok, receipt} = Budgets.reserve(receipt, 100, 100)
    {:ok, receipt} = Budgets.dispatch(receipt)

    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT reject_budget_reconciliation CHECK (event_type <> 'budget.reconciled')",
      []
    )

    assert {:error, :audit_unavailable} = Budgets.reconcile(context.scope, receipt.id, :not_sent)
    assert bucket(context).reserved == 200
  end
end
