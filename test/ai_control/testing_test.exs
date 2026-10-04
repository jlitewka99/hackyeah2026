defmodule AiControl.TestingTest do
  use AiControl.DataCase, async: false

  import AiControl.OrganizationsFixtures

  alias AiControl.Background
  alias AiControl.Background.Workers.GatewayTests
  alias AiControl.Organizations.Organization
  alias AiControl.Repo
  alias AiControl.Testing.{ProcessExecutor, Protocol}
  alias AiControl.Testing.Suite

  setup do
    config = Application.get_env(:ai_control, ProcessExecutor, [])
    on_exit(fn -> Application.put_env(:ai_control, ProcessExecutor, config) end)
    %{runner_config: config}
  end

  test "missing, encoded primary and overriding database URLs cannot start a runner" do
    main = Repo.config()[:database]

    for url <- [
          nil,
          "ecto://localhost/#{main}",
          "ecto://localhost/%61" <> String.slice(main, 1..-1//1),
          "ecto://localhost/separate?database=#{main}"
        ] do
      Application.put_env(:ai_control, ProcessExecutor, database_url: url)
      assert {:error, :runner_unavailable} = ProcessExecutor.database()
    end
  end

  test "IPC accepts counters and rejects raw payloads and extra fields" do
    row = %{
      "case_id" => "allow",
      "status" => "passed",
      "duration_us" => 10,
      "evidence" => %{"http_status" => 200}
    }

    assert {:ok, ^row} = Protocol.case_result(row)
    assert {:error, :invalid_result} = Protocol.case_result(Map.put(row, "prompt", "private"))

    assert {:error, :invalid_result} =
             Protocol.case_result(put_in(row, ["evidence", "token"], "secret"))

    assert {:error, :invalid_result} = Protocol.case_result(put_in(row, ["status"], "success"))
  end

  @tag :runner
  @tag timeout: 180_000
  test "separate process executes real HTTP, audit, budgets and sandbox without writing primary fixtures",
       %{runner_config: config} do
    assert config[:database_url]
    scope = organization_fixture()
    before = Repo.aggregate(Organization, :count)
    {:ok, run} = Background.enqueue(scope, "gateway_tests")
    job = %{Repo.get!(Oban.Job, run.job_id) | attempt: 1}
    assert :ok = GatewayTests.perform(job)
    assert {:ok, cases} = Background.cases(scope, run.id)

    assert Enum.sort(Enum.map(cases, & &1.case_id)) ==
             Enum.sort(Suite.case_ids())

    assert Enum.all?(cases, &(&1.status == "passed"))
    assert Repo.aggregate(Organization, :count) == before
    assert {:ok, completed} = Background.fetch(scope, run.id)
    assert completed.result["passed"] == 15
    refute Jason.encode!(completed.result) =~ "runner@example"
  end

  @tag :runner
  @tag timeout: 180_000
  test "cancelling during IPC stops further scenarios and closes the child" do
    scope = organization_fixture()
    {:ok, run} = Background.enqueue(scope, "gateway_tests")
    parent = self()

    assert {:error, :access_revoked} =
             ProcessExecutor.run(run, fn row ->
               send(parent, {:case, row["case_id"]})
               :ok = Background.cancel(scope, run.id)
               :ok
             end)

    assert_receive {:case, "allow"}
    refute_receive {:case, _}
    assert {:ok, %{status: "cancelled"}} = Background.fetch(scope, run.id)
  end
end
