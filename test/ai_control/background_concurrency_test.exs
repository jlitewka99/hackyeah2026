defmodule AiControl.BackgroundConcurrencyTest do
  use ExUnit.Case, async: false

  import AiControl.OrganizationsFixtures
  import Ecto.Query

  alias AiControl.Accounts.User
  alias AiControl.{Background, Repo}
  alias AiControl.Background.Run
  alias Ecto.Adapters.SQL.Sandbox

  test "competing connections create one active run and one durable job" do
    supervisor = start_supervised!(Task.Supervisor)

    Sandbox.unboxed_run(Repo, fn ->
      previous_organizer = Repo.one(from(u in User, where: u.organizer))
      scope = organization_fixture()

      try do
        tasks =
          for _ <- 1..4 do
            Task.Supervisor.async_nolink(supervisor, fn ->
              Sandbox.unboxed_run(Repo, fn -> Background.enqueue(scope, "gateway_tests") end)
            end)
          end

        runs =
          Enum.map(tasks, fn task ->
            assert {:ok, run} = Task.await(task, 10_000)
            run
          end)

        assert [run_id] = runs |> Enum.map(& &1.id) |> Enum.uniq()
        run = Repo.get!(Run, run_id)
        assert Repo.get!(Oban.Job, run.job_id).args["run_id"] == run.id

        assert Repo.aggregate(
                 from(r in Run, where: r.organization_id == ^scope.organization.id),
                 :count
               ) == 1
      after
        job_ids =
          Repo.all(
            from(r in Run, where: r.organization_id == ^scope.organization.id, select: r.job_id)
          )

        Repo.delete_all(from(r in Run, where: r.organization_id == ^scope.organization.id))
        Repo.delete_all(from(j in Oban.Job, where: j.id in ^job_ids))

        Repo.delete_all(
          from(e in AiControl.Audit.Event, where: e.organization_id == ^scope.organization.id)
        )

        Repo.delete!(scope.organization)
        if is_nil(previous_organizer), do: Repo.delete!(scope.user)
      end
    end)
  end
end
