defmodule AiControl.BackgroundTest do
  use AiControl.DataCase, async: false

  import AiControl.OrganizationsFixtures

  alias AiControl.{Audit, Background, Organizations, Repo}
  alias AiControl.Background.{Chunk, Run}
  alias AiControl.Background.Workers.{AuditExport, Cleanup, MetricsReport}

  test "partial scenarios expire after seven days while run metadata and primary audit survive" do
    scope = organization_fixture()
    {:ok, run} = Background.enqueue(scope, "gateway_tests")

    Repo.insert!(%AiControl.Background.CaseResult{
      run_id: run.id,
      case_id: "allow",
      status: "passed",
      duration_us: 1,
      evidence: %{}
    })

    :ok = Background.cancel(scope, run.id)
    cancelled = Repo.get!(Run, run.id)
    assert cancelled.expires_at

    Repo.update!(
      Ecto.Changeset.change(cancelled, expires_at: DateTime.add(DateTime.utc_now(), -1))
    )

    assert {:ok, []} = Background.cases(scope, run.id)
    assert :ok = Cleanup.perform(%Oban.Job{})
    assert Repo.aggregate(AiControl.Background.CaseResult, :count) == 0
    assert {:ok, %{status: "cancelled"}} = Background.fetch(scope, run.id)
  end

  test "terminal Oban state recovers a run after a worker dies outside its callback" do
    scope = organization_fixture()
    {:ok, run} = Background.enqueue(scope, "gateway_tests")
    {:ok, _} = Background.update(run, status: "running")
    Repo.update_all(from(j in Oban.Job, where: j.id == ^run.job_id), set: [state: "discarded"])
    assert :ok = Background.reconcile()

    assert {:ok, %{status: "failed", error_code: "job_unavailable"}} =
             Background.fetch(scope, run.id)

    assert {:ok, next} = Background.enqueue(scope, "gateway_tests")
    refute next.id == run.id
  end

  test "enqueue is atomic, active work is deduplicated and arguments contain only identities" do
    scope = organization_fixture()
    assert {:ok, first} = Background.enqueue(scope, "gateway_tests")
    assert {:ok, second} = Background.enqueue(scope, "gateway_tests")
    assert second.id == first.id
    assert Repo.aggregate(Oban.Job, :count) == 1
    job = Repo.get!(Oban.Job, first.job_id)

    assert job.args == %{
             "run_id" => first.id,
             "organization_id" => scope.organization.id,
             "user_id" => scope.user.id
           }

    assert {:error, :invalid_job} =
             Background.enqueue(scope, "gateway_tests", %{"suite" => "shell", "mode" => "live"})

    assert {:error, :invalid_job} =
             Background.enqueue(scope, "benchmark", %{"mode" => "controlled"})

    assert :ok = Background.cancel(scope, first.id)
    assert {:ok, third} = Background.enqueue(scope, "gateway_tests")
    refute third.id == first.id
    assert {:ok, export} = Background.enqueue(scope, "audit_export")
    assert {:ok, same} = Background.enqueue(scope, "audit_export")
    assert same.id == export.id
  end

  test "organization isolation, current permissions and mid-work revocation" do
    scope = organization_fixture()
    other = organization_fixture()
    member = member_fixture(scope, :user, %{permissions: ["events.read", "events.export"]})
    {:ok, run} = Background.enqueue(member.scope, "audit_export")
    assert {:error, :forbidden} = Background.fetch(other, run.id)
    job = job(run)

    assert {:cancel, "access_revoked"} =
             Background.work(job, fn run, _ ->
               {:ok, _} =
                 Organizations.update_member(scope, member.membership.id, %{
                   grants: %{permissions: ["events.read"]}
                 })

               assert {:error, :access_revoked} = Background.put_chunk(run, 0, "discarded")
               {:ok, %{}}
             end)

    assert Repo.get!(Run, run.id).status == "cancelled"
    assert Repo.aggregate(Chunk, :count) == 0
  end

  test "revocation before execution prevents any worker output" do
    scope = organization_fixture()
    member = member_fixture(scope, :user, %{permissions: ["events.read", "events.export"]})
    {:ok, run} = Background.enqueue(member.scope, "audit_export")
    {:ok, _} = Organizations.remove_member(scope, member.membership.id)
    assert {:cancel, "access_revoked"} = AuditExport.perform(job(run))
    assert {:error, :forbidden} = Background.fetch(member.scope, run.id)
    assert Repo.aggregate(Chunk, :count) == 0
  end

  test "committed JSONL export has one completion marker and retry preserves its checksum" do
    scope = organization_fixture()
    for _ <- 1..503, do: Audit.record_gateway(scope, Ecto.UUID.generate(), "completed", 10)
    {:ok, run} = Background.enqueue(scope, "audit_export", %{"filters" => %{"kind" => "gateway"}})
    assert :ok = AuditExport.perform(job(run))
    {:ok, completed} = Background.fetch(scope, run.id)
    assert completed.total == 503
    assert completed.progress == 503
    assert completed.spec["filters"]["range"] == "custom"
    assert :ok = AuditExport.perform(job(run))
    chunks = Repo.all(from(c in Chunk, where: c.run_id == ^run.id, order_by: c.position))
    assert length(chunks) == 3

    rows =
      Enum.flat_map(chunks, &String.split(&1.data, "\n", trim: true))
      |> Enum.map(&Jason.decode!/1)

    assert List.last(rows) == %{
             "type" => "export_complete",
             "schema_version" => 1,
             "count" => 503
           }

    ids = for %{"type" => "event", "event" => %{"id" => id}} <- rows, do: id
    assert length(Enum.uniq(ids)) == 503
    assert {:ok, checksum} = Background.checksum(completed)
    assert checksum == completed.checksum
  end

  test "a persisted manifest resumes after a restart without admitting later events" do
    scope = organization_fixture()
    {:ok, event} = Audit.record_gateway(scope, Ecto.UUID.generate(), "completed", 10)
    {:ok, run} = Background.enqueue(scope, "audit_export", %{"filters" => %{"kind" => "gateway"}})

    Repo.insert_all(AiControl.Background.ExportEvent, [
      %{run_id: run.id, position: 1, event_id: event.id}
    ])

    {:ok, run} = Background.update(run, manifest_ready: true, total: 1)
    {:ok, _} = Audit.record_gateway(scope, Ecto.UUID.generate(), "completed", 10)
    assert :ok = AuditExport.perform(job(run))
    {:ok, [chunk]} = Background.chunk_page(scope, run.id)
    assert length(String.split(chunk.data, "\n", trim: true)) == 1
  end

  test "budget-bearing report is unreadable after budgets.read is revoked; expiration deletes auxiliary data only" do
    scope = organization_fixture()
    member = member_fixture(scope, :user, %{permissions: ["events.read", "budgets.read"]})
    {:ok, run} = Background.enqueue(member.scope, "metrics_report", %{"include_budgets" => true})
    assert "budgets.read" in run.permissions
    assert :ok = MetricsReport.perform(job(run))
    assert {:ok, completed} = Background.artifact(member.scope, run.id)
    assert completed.result["latency_unit"] == "microseconds"

    {:ok, _} =
      Organizations.update_member(scope, member.membership.id, %{
        grants: %{permissions: ["events.read"]}
      })

    assert {:error, :forbidden} = Background.fetch(member.scope, run.id)
    assert {:ok, []} = Background.list(member.scope, ["metrics_report"])

    Repo.update!(
      Ecto.Changeset.change(completed, expires_at: DateTime.add(DateTime.utc_now(), -1))
    )

    primary_count = Repo.aggregate(AiControl.Audit.Event, :count)
    assert :ok = Cleanup.perform(%Oban.Job{})
    assert Repo.aggregate(AiControl.Audit.Event, :count) == primary_count
    assert Repo.aggregate(Chunk, :count) == 0
    assert {:error, :artifact_unavailable} = Background.artifact(scope, run.id)
  end

  test "a queue failure never affects synchronous gateway audit" do
    scope = organization_fixture()
    assert {:ok, _} = Audit.record_gateway(scope, Ecto.UUID.generate(), "completed", 7)
    assert {:error, _} = Background.enqueue(scope, "invalid")
    assert {:ok, events} = Audit.list_events(scope)
    assert Enum.any?(events, &(&1.event_type == "gateway.completed"))
  end

  defp job(run), do: %{Repo.get!(Oban.Job, run.job_id) | attempt: 1}
end
