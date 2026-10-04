defmodule AiControl.Workflows.DomainTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures
  import AiControl.WorkflowsFixtures

  alias AiControl.{ApiKeys, Policies, Workflows}
  alias AiControl.Audit.Serializer
  alias AiControl.Gateway.Request
  alias AiControl.Workflows.{Operation, Run}
  alias Ecto.Adapters.SQL

  test "creation and delegation are idempotent and never let a parent act as its child" do
    c = workflow_fixture()

    assert {:ok, {same, root}} =
             Workflows.create(c.principal, %{"goal" => c.run.goal}, c.run.idempotency_key)

    assert same.id == c.run.id
    assert root.id == c.participant.id

    assert {:error, :workflow_conflict} =
             Workflows.create(
               c.principal,
               %{"goal" => "Another objective"},
               c.run.idempotency_key
             )

    other = agent_fixture(c.scope)
    key = Ecto.UUID.generate()

    assert {:ok, child} =
             Workflows.delegate(
               c.principal,
               c.run.id,
               root.id,
               %{"target_agent_id" => other.id},
               key
             )

    assert {:ok, same_child} =
             Workflows.delegate(
               c.principal,
               c.run.id,
               root.id,
               %{"target_agent_id" => other.id},
               key
             )

    assert child.id == same_child.id
    assert Repo.get!(Run, c.run.id).calls == 1

    assert {:error, :forbidden} =
             Workflows.resolve(c.principal, c.policy, %{
               run_id: c.run.id,
               participant_id: child.id
             })

    target = principal_fixture(c.scope, other)

    assert {:ok, ctx} =
             Workflows.resolve(target, c.policy, %{run_id: c.run.id, participant_id: child.id})

    assert ctx.agent_id == other.id
  end

  test "fourth identical action terminates the root even when actions alternate" do
    c = workflow_fixture()

    for i <- 1..3 do
      assert {:ok, _} = Workflows.admit(c.reference, c.policy, "chat", %{"message" => "same"})

      assert {:ok, _} =
               Workflows.admit(c.reference, c.policy, "chat", %{"message" => "different #{i}"})
    end

    assert {:error, :workflow_limit_exceeded} =
             Workflows.admit(c.reference, c.policy, "chat", %{"message" => "same"})

    stored = Repo.get!(Run, c.run.id)
    assert stored.status == "limit_exceeded"
    assert stored.reason == "max_repeated_actions"
    assert stored.calls == 6
    assert {:error, :workflow_terminal} = Workflows.resolve(c.principal, c.policy, c.reference)
  end

  test "transport IDs, stream flags and JSON argument order cannot reset repetitions" do
    c = workflow_fixture()

    for i <- 1..4 do
      call_id = "synthetic-#{i}"
      arguments = if rem(i, 2) == 0, do: ~s({"a":1,"b":2}), else: ~s({"b":2,"a":1})

      {:ok, payload} =
        Request.validate(%{
          "model" => "qwen3.5:4b",
          "stream" => rem(i, 2) == 0,
          "messages" => [
            %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => call_id,
                  "type" => "function",
                  "function" => %{"name" => "synthetic_lookup", "arguments" => arguments}
                }
              ]
            },
            %{"role" => "tool", "tool_call_id" => call_id, "content" => "Synthetic result"}
          ]
        })

      result = Workflows.admit(c.reference, c.policy, "chat", payload)

      if i < 4,
        do: assert({:ok, _} = result),
        else: assert({:error, :workflow_limit_exceeded} = result)
    end

    assert Repo.get!(Run, c.run.id).reason == "max_repeated_actions"
  end

  test "depth zero denies delegation and a cycle cannot escape the shared operation cap" do
    c = workflow_fixture(%{"max_delegation_depth" => 0})
    other = agent_fixture(c.scope)

    assert {:error, :workflow_limit_exceeded} =
             Workflows.delegate(
               c.principal,
               c.run.id,
               c.participant.id,
               %{"target_agent_id" => other.id},
               Ecto.UUID.generate()
             )

    assert Repo.get!(Run, c.run.id).reason == "max_delegation_depth"
  end

  test "operation limit is persistent, retries do not consume it, and completion refuses active operations" do
    c = workflow_fixture(%{"max_calls" => 1})
    id = Ecto.UUID.generate()
    assert {:ok, operation} = Workflows.admit(c.reference, c.policy, "chat", %{}, id)
    assert {:ok, repeated} = Workflows.admit(c.reference, c.policy, "chat", %{}, id)
    assert operation.operation_id == repeated.operation_id
    assert Repo.get!(Run, c.run.id).calls == 1
    assert {:error, :workflow_conflict} = Workflows.transition(c.principal, c.run.id, "complete")

    assert {:error, :workflow_limit_exceeded} =
             Workflows.admit(c.reference, c.policy, "chat", %{"new" => true})

    assert Repo.aggregate(Operation, :count) == 1
  end

  test "new policies can tighten limits but cannot raise them" do
    c = workflow_fixture(%{"max_calls" => 2})
    activate_workflows(c.scope, %{"max_calls" => 100})
    {:ok, policy, _} = Policies.snapshot_for_models(c.principal, nil)
    assert {:ok, _} = Workflows.resolve(c.principal, policy, c.reference)
    assert Repo.get!(Run, c.run.id).limits["max_calls"] == 2
    activate_workflows(c.scope, %{"max_calls" => 0})
    {:ok, policy, _} = Policies.snapshot_for_models(c.principal, nil)
    assert {:ok, _} = Workflows.resolve(c.principal, policy, c.reference)
    assert {:error, :workflow_limit_exceeded} = Workflows.admit(c.reference, policy, "chat", %{})
  end

  test "the exact controlled deadline terminates the run" do
    c = workflow_fixture()
    clock = start_supervised!({Agent, fn -> c.run.deadline end})
    Application.put_env(:ai_control, Workflows, clock: fn -> Agent.get(clock, & &1) end)
    on_exit(fn -> Application.delete_env(:ai_control, Workflows) end)

    [{runtime, _}] =
      Registry.lookup(AiControl.Workflows.Registry, {c.run.organization_id, c.run.id})

    ref = Process.monitor(runtime)
    send(runtime, :deadline)
    assert_receive {:DOWN, ^ref, :process, ^runtime, :normal}, 2000
    :sys.get_state(AiControl.Workflows.Manager)
    assert Repo.get!(Run, c.run.id).reason == "max_duration_seconds"
  end

  test "an in-flight local worker times out and cannot keep the workflow running" do
    c = workflow_fixture()
    {:ok, ctx} = Workflows.admit(c.reference, c.policy, "chat", %{"synthetic" => "timeout"})
    clock = start_supervised!({Agent, fn -> DateTime.add(c.run.deadline, -200, :millisecond) end})
    Application.put_env(:ai_control, Workflows, clock: fn -> Agent.get(clock, & &1) end)
    on_exit(fn -> Application.delete_env(:ai_control, Workflows) end)
    supervisor = start_supervised!(Task.Supervisor)
    owner = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Workflows.run(ctx, fn ->
          send(owner, {:worker_started, self()})

          receive do
            :continue -> :ok
          end
        end)
      end)

    assert_receive {:worker_started, worker}, 2000
    ref = Process.monitor(worker)
    Agent.update(clock, fn _ -> c.run.deadline end)
    assert {:error, :workflow_limit_exceeded} = Task.await(task, 2000)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 2000
    assert Repo.get!(Run, c.run.id).reason == "max_duration_seconds"
  end

  test "foreign organizations and key revocation cannot continue a run" do
    c = workflow_fixture()
    other_scope = organization_fixture()
    other_agent = agent_fixture(other_scope)
    other = principal_fixture(other_scope, other_agent)
    assert {:error, :forbidden} = Workflows.fetch(other, c.run.id)
    assert {:error, :forbidden} = Workflows.resolve(other, c.policy, c.reference)
    assert {:ok, _} = ApiKeys.revoke_key(c.scope, c.principal.api_key_id)
    assert {:error, :forbidden} = Workflows.resolve(c.principal, c.policy, c.reference)
  end

  test "complete and stop are terminal; goal never enters audit" do
    c = workflow_fixture()
    assert {:ok, run} = Workflows.transition(c.principal, c.run.id, "complete")
    assert run.status == "completed"
    assert {:ok, _} = Workflows.transition(c.principal, c.run.id, "complete")
    assert {:error, :workflow_terminal} = Workflows.admit(c.reference, c.policy, "chat", %{})
    events = Repo.all(AiControl.Audit.Event)

    refute Enum.any?(events, fn e ->
             Jason.encode!(Serializer.event(e)) =~ c.run.goal
           end)

    assert Enum.any?(events, &(&1.event_type == "workflow.completed" && &1.run_id == c.run.id))
  end

  test "A to B to A uses server depths and repeats across participant identities" do
    c = workflow_fixture()
    b = agent_fixture(c.scope)
    b_key = principal_fixture(c.scope, b)

    {:ok, b_participant} =
      Workflows.delegate(
        c.principal,
        c.run.id,
        c.participant.id,
        %{"target_agent_id" => b.id},
        Ecto.UUID.generate()
      )

    {:ok, a_again} =
      Workflows.delegate(
        b_key,
        c.run.id,
        b_participant.id,
        %{"target_agent_id" => c.agent.id},
        Ecto.UUID.generate()
      )

    assert {b_participant.depth, a_again.depth} == {1, 2}

    {:ok, b_context} =
      Workflows.resolve(b_key, c.policy, %{run_id: c.run.id, participant_id: b_participant.id})

    {:ok, a_context} =
      Workflows.resolve(c.principal, c.policy, %{run_id: c.run.id, participant_id: a_again.id})

    for ctx <- [c.reference, b_context, a_context],
        do: assert({:ok, _} = Workflows.admit(ctx, c.policy, "chat", %{"same" => true}))

    assert {:error, :workflow_limit_exceeded} =
             Workflows.admit(b_context, c.policy, "chat", %{"same" => true})

    assert Repo.get!(Run, c.run.id).reason == "max_repeated_actions"
  end

  test "workflow audit failure rolls back creation and terminal mutation" do
    c = workflow_fixture(%{"max_calls" => 0})

    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT reject_workflow_audit CHECK (event_type NOT IN ('workflow.created','workflow.limit_exceeded')) NOT VALID",
      []
    )

    assert {:error, :audit_unavailable} =
             Workflows.create(
               c.principal,
               %{"goal" => "Synthetic audit failure"},
               Ecto.UUID.generate()
             )

    assert Repo.aggregate(Run, :count) == 1
    assert {:error, :audit_unavailable} = Workflows.admit(c.reference, c.policy, "chat", %{})
    assert Repo.get!(Run, c.run.id).status == "running"
    assert Repo.get!(Run, c.run.id).calls == 0
  end
end
