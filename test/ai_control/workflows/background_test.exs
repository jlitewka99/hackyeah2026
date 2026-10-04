defmodule AiControl.Workflows.BackgroundTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures
  import AiControl.WorkflowsFixtures

  alias AiControl.{Background, Organizations, Repo, Workflows}
  alias AiControl.Background.Chunk
  alias AiControl.Background.Workers.AuditExport

  test "background JSONL excludes unassigned workflow participants and other owners" do
    c = workflow_fixture()
    target = agent_fixture(c.scope)
    identity = AiControl.GatewayFixtures.principal_fixture(c.scope, target)
    other = run_reference_fixture(identity)

    {:ok, child} =
      Workflows.delegate(
        c.principal,
        c.run.id,
        c.participant.id,
        %{"target_agent_id" => target.id},
        Ecto.UUID.generate()
      )

    member =
      member_fixture(c.scope, :user, %{
        permissions: ["events.read", "events.export"],
        agents: [c.agent.id]
      })

    {:ok, run} = Background.enqueue(member.scope, "audit_export")
    assert :ok = AuditExport.perform(job(run))
    {:ok, completed} = Background.fetch(member.scope, run.id)
    assert completed.spec["workflow_agents"] == [c.agent.id]
    data = export_data(run)
    assert data =~ c.run.id
    refute data =~ other.run_id
    refute data =~ child.id
    refute data =~ target.id
  end

  test "changing agent assignments blocks a completed background workflow export" do
    c = workflow_fixture()

    member =
      member_fixture(c.scope, :user, %{
        permissions: ["events.read", "events.export"],
        agents: [c.agent.id]
      })

    {:ok, run} = Background.enqueue(member.scope, "audit_export")
    assert :ok = AuditExport.perform(job(run))
    assert {:ok, _} = Background.artifact(member.scope, run.id)

    {:ok, _} =
      Organizations.update_member(c.scope, member.membership.id, %{
        grants: %{permissions: ["events.read", "events.export"], agents: []}
      })

    assert {:error, :artifact_unavailable} = Background.artifact(member.scope, run.id)
    assert {:error, :artifact_unavailable} = Background.chunk_page(member.scope, run.id)
  end

  test "assignment revocation after a persisted manifest prevents the resumed batch" do
    c = workflow_fixture()

    member =
      member_fixture(c.scope, :user, %{
        permissions: ["events.read", "events.export"],
        agents: [c.agent.id]
      })

    {:ok, run} = Background.enqueue(member.scope, "audit_export")
    event = Repo.one!(from(e in AiControl.Audit.Event, where: e.run_id == ^c.run.id, limit: 1))

    Repo.insert!(%AiControl.Background.ExportEvent{
      run_id: run.id,
      position: 1,
      event_id: event.id
    })

    {:ok, _} =
      Background.update(run,
        manifest_ready: true,
        total: 1,
        spec: Map.put(run.spec, "workflow_agents", [c.agent.id])
      )

    {:ok, _} =
      Organizations.update_member(c.scope, member.membership.id, %{
        grants: %{permissions: ["events.read", "events.export"], agents: []}
      })

    assert {:cancel, "access_revoked"} = AuditExport.perform(job(run))
    assert export_data(run) == ""
    assert {:ok, %{status: "cancelled"}} = Background.fetch(member.scope, run.id)
  end

  defp job(run), do: Repo.get!(Oban.Job, run.job_id)

  defp export_data(run) do
    Repo.all(from(c in Chunk, where: c.run_id == ^run.id, order_by: c.position))
    |> Enum.map_join(& &1.data)
  end
end
