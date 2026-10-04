defmodule AiControl.Audit.CommittedExportTest do
  use ExUnit.Case, async: false

  import AiControl.OrganizationsFixtures
  import Ecto.Query

  alias AiControl.Accounts.User
  alias AiControl.{Audit, Organizations, Repo}
  alias AiControl.Audit.{Event, Export, Filters}
  alias AiControl.Organizations.Organization
  alias Ecto.Adapters.SQL.Sandbox

  test "committed audit writes notify and READ COMMITTED export observes another connection's revocation" do
    supervisor = start_supervised!(Task.Supervisor)

    Sandbox.unboxed_run(Repo, fn ->
      previous_organizer = Repo.one(from(u in User, where: u.organizer))
      scope = organization_fixture()
      reader = member_fixture(scope, :user, %{permissions: ["events.read", "events.export"]})

      try do
        Phoenix.PubSub.subscribe(
          AiControl.PubSub,
          "organizations:#{scope.organization.id}:dashboard"
        )

        assert {:ok, event} = Audit.record_gateway(scope, Ecto.UUID.generate(), "completed", 1)
        assert_received :dashboard_changed
        attrs = event |> Map.from_struct() |> Map.drop([:__meta__, :id])

        Repo.insert_all(
          Event,
          Enum.map(1..500, fn _ ->
            Map.merge(attrs, %{
              id: Ecto.UUID.generate(),
              request_id: Ecto.UUID.generate(),
              target_id: Ecto.UUID.generate()
            })
          end), log: false)

        {:ok, filters} = Filters.parse(%{"kind" => "gateway"})

        assert {:error, :export_interrupted} =
                 Export.run(reader.scope, filters, nil, fn state, lines ->
                   send(self(), {:batch, length(lines)})

                   task =
                     Task.Supervisor.async_nolink(supervisor, fn ->
                       Sandbox.unboxed_run(Repo, fn ->
                         Organizations.update_member(scope, reader.membership.id, %{
                           grants: %{permissions: ["events.read"]}
                         })
                       end)
                     end)

                   assert {:ok, _} = Task.await(task)
                   {:ok, state}
                 end)

        assert_received {:batch, 500}
        refute_received {:batch, _}
        assert {:error, :forbidden} = Export.authorize(reader.scope)
        assert Repo.aggregate(Event, :count, :id) >= 501
      after
        Repo.delete_all(from(e in Event, where: e.organization_id == ^scope.organization.id))
        Repo.delete!(Repo.get!(Organization, scope.organization.id))
        Repo.delete!(Repo.get!(User, reader.user.id))
        if is_nil(previous_organizer), do: Repo.delete!(Repo.get!(User, scope.user.id))
      end
    end)
  end
end
