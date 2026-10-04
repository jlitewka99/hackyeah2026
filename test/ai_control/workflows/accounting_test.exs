defmodule AiControl.Workflows.AccountingTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.SecurityFixtures
  import AiControl.WorkflowsFixtures

  alias AiControl.{Budgets, Gateway, Tools, Workflows}
  alias AiControl.Budgets.Reservation
  alias AiControl.Gateway.Config
  alias AiControl.Policies.Configuration
  alias AiControl.Security.GuardResult
  alias AiControl.Workflows.{Operation, Run}

  setup do
    old = Application.fetch_env!(:ai_control, Config)

    Application.put_env(
      :ai_control,
      Config,
      old
      |> Keyword.put(:http_plug, {Req.Test, __MODULE__})
      |> Keyword.put(:tokenizer, AiControl.TestBudgetTokenizer)
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/models" ->
          Req.Test.json(conn, %{
            data: [%{id: "deepseek-flash"}]
          })

        _ ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          params = Jason.decode!(body)
          if callback = Config.get()[:test_transport], do: callback.(params)

          Req.Test.json(conn, response())
      end
    end)

    :ok
  end

  test "workflow reserves and settles target tokens with no hourly token limit" do
    c = workflow_fixture(%{"max_tokens" => 16})

    assert {:ok, _} =
             Gateway.chat(c.principal, Map.put(request(), "max_tokens", 4),
               run_context: c.reference
             )

    run = Repo.get!(Run, c.run.id)
    assert {run.tokens, run.reserved_tokens, run.calls} == {16, 0, 1}
    receipt = Repo.get_by!(Reservation, run_id: run.id)
    assert receipt.status == "settled"
    assert receipt.participant_id == c.participant.id

    assert {:error, :workflow_limit_exceeded} =
             Gateway.chat(c.principal, Map.put(request(), "max_tokens", 4),
               run_context: c.reference
             )

    assert Repo.get!(Run, run.id).reason == "max_tokens"
  end

  test "missing v5 context is rejected at both domain entrypoints" do
    c = workflow_fixture()
    assert {:error, :workflow_context_required} = Gateway.chat(c.principal, request())

    assert {:error, :workflow_context_required} =
             Tools.execute(
               c.principal,
               %{"tool" => "file.read", "arguments" => %{"path" => "report.txt"}},
               idempotency_key: Ecto.UUID.generate()
             )

    assert Repo.get!(Run, c.run.id).calls == 0
  end

  test "siblings share the existing persistent tool counter and retries do not charge" do
    c = workflow_fixture(%{"tool_calls" => 1})
    other = agent_fixture(c.scope)
    child_key = principal_fixture(c.scope, other)

    {:ok, child} =
      Workflows.delegate(
        c.principal,
        c.run.id,
        c.participant.id,
        %{"target_agent_id" => other.id},
        Ecto.UUID.generate()
      )

    {:ok, ctx} =
      Workflows.resolve(child_key, c.policy, %{run_id: c.run.id, participant_id: child.id})

    :sys.replace_state(c.sandbox, fn state ->
      %{state | grants: Map.put(state.grants, other.id, state.grants[c.agent.id]), contexts: %{}}
    end)

    params = %{"tool" => "file.read", "arguments" => %{"path" => "report.txt"}}
    key = Ecto.UUID.generate()
    assert {:ok, _} = Tools.execute(child_key, params, run_context: ctx, idempotency_key: key)

    assert {:error, {:tool_execution_exists, _}} =
             Tools.execute(child_key, params, run_context: ctx, idempotency_key: key)

    assert Repo.get!(Run, c.run.id).calls == 2
    assert Workflows.evidence(Repo.get!(Run, c.run.id)).tool_calls == 1

    assert {:error, :workflow_limit_exceeded} =
             Tools.execute(c.principal, params,
               run_context: c.reference,
               idempotency_key: Ecto.UUID.generate()
             )

    assert Repo.get!(Run, c.run.id).reason == "tool_calls"
  end

  test "a stop before dispatch releases reservations and starts no downstream generation" do
    c = workflow_fixture()
    owner = self()

    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:test_tokenizer, fn _, _ ->
        send(owner, {:preparing, self()})

        receive do
          :continue -> {:ok, 12}
        end
      end)
      |> Keyword.put(:test_transport, fn _ -> send(owner, :generated) end)
    )

    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Gateway.chat(c.principal, request(), run_context: c.reference)
      end)

    assert_receive {:preparing, _pid}, 2000
    assert {:ok, _} = Workflows.transition(c.principal, c.run.id, "stop")
    assert {:error, :workflow_terminal} = Task.await(task, 2000)
    refute_received :generated
    assert Repo.get!(Run, c.run.id).reserved_tokens == 0
  end

  test "stop after dispatch keeps an uncertain charge and never repeats an effect" do
    c = workflow_fixture()
    owner = self()

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :test_transport, fn _ ->
        send(owner, {:dispatched, self()})

        receive do
          :continue -> :ok
        end
      end)
    )

    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Gateway.chat(c.principal, request(), run_context: c.reference)
      end)

    assert_receive {:dispatched, _pid}, 2000
    assert {:ok, _} = Workflows.transition(c.principal, c.run.id, "stop")
    assert {:error, :workflow_terminal} = Task.await(task, 2000)
    receipt = Repo.get_by!(Reservation, run_id: c.run.id)
    assert receipt.status == "uncertain"
    assert Repo.get!(Run, c.run.id).reserved_tokens == 1036
    assert Repo.get_by!(Operation, run_id: c.run.id).status == "uncertain"

    assert {:error, :workflow_terminal} =
             Gateway.chat(c.principal, request(), run_context: c.reference)
  end

  test "a new UTC hour does not replenish the root budget and reconciliation settles once" do
    c = workflow_fixture(%{"max_tokens" => 20})
    {:ok, ctx} = Workflows.admit(c.reference, c.policy, "chat", request())
    op = Repo.get!(Operation, ctx.operation_id)

    {:ok, receipt} =
      Budgets.admit(
        c.principal,
        nil,
        request()["model"],
        c.policy,
        op.request_id,
        ~U[2026-10-04 00:59:59Z],
        ctx
      )

    {:ok, receipt} = Budgets.reserve(receipt, 12, 4)
    {:ok, receipt} = Budgets.dispatch(receipt)
    {:ok, receipt} = Budgets.abandon(receipt)
    assert Repo.get!(Run, c.run.id).reserved_tokens == 16
    {:ok, settled} = Budgets.reconcile(c.scope, receipt.id, response()["usage"])
    assert settled.status == "settled"
    {:ok, ctx2} = Workflows.admit(c.reference, c.policy, "chat", %{"second" => true})
    op2 = Repo.get!(Operation, ctx2.operation_id)

    {:ok, receipt2} =
      Budgets.admit(
        c.principal,
        nil,
        request()["model"],
        c.policy,
        op2.request_id,
        ~U[2026-10-04 01:00:01Z],
        ctx2
      )

    assert {:error, :workflow_limit_exceeded} = Budgets.reserve(receipt2, 12, 4)
    assert Repo.get!(Run, c.run.id).tokens == 16
  end

  test "an output guard rejection still settles actual target-model usage" do
    c = workflow_fixture()

    guards =
      Map.new(Configuration.guards(5), &{&1, %{"enabled" => false, "required" => false}})
      |> Map.put("pii", %{"enabled" => true, "required" => true, "stages" => ["output"]})

    activate_workflows(c.scope, %{}, %{
      "guards" => guards,
      "rules" => %{"pii" => %{"action" => "block"}}
    })

    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:guards, %{"pii" => AiControl.TestGatewayGuard})
      |> Keyword.put(:test_guard, fn _, _ ->
        GuardResult.new(%{
          guard: "pii",
          status: :ok,
          detections: [
            detection_fixture(%{location: %{field_index: 0, start_byte: 0, end_byte: 1}})
          ]
        })
      end)
    )

    assert {:error, :policy_blocked} =
             Gateway.chat(c.principal, request(), run_context: c.reference)

    run = Repo.get!(Run, c.run.id)
    assert {run.tokens, run.reserved_tokens, run.calls} == {16, 0, 1}
    assert Repo.get_by!(Reservation, run_id: run.id).status == "settled"
  end

  test "tightening during preparation is enforced using the current policy at dispatch" do
    c = workflow_fixture()
    {:ok, ctx} = Workflows.admit(c.reference, c.policy, "tool", %{"tool" => "file.read"})
    activate_workflows(c.scope, %{"tool_calls" => 0})

    assert {:error, :workflow_limit_exceeded} =
             Budgets.consume_tool_call(
               c.principal,
               nil,
               c.policy,
               c.run.id,
               Ecto.UUID.generate(),
               ctx
             )

    run = Repo.get!(Run, c.run.id)
    assert run.reason == "tool_calls"
    assert Workflows.evidence(run).tool_calls == 0
  end
end
