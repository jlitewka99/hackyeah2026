defmodule AiControl.Policies.Bootstrap do
  @moduledoc "Append the current default only for a pristine installation; never migrate user policies."
  import Ecto.Query

  alias AiControl.Policies.{Activation, Configuration, Set, Version}
  alias AiControl.Policy.Snapshot

  def seed_new_installation(repo) do
    repo.transact(fn ->
      set = repo.one!(from(s in Set, where: is_nil(s.organization_id), lock: "FOR UPDATE"))

      pristine? =
        set.revision == 1 &&
          !repo.exists?(AiControl.Accounts.User) &&
          !repo.exists?(AiControl.Organizations.Organization) &&
          repo.aggregate(Version, :count) == 1

      if pristine?, do: append_default(repo, set)
      {:ok, :ok}
    end)
  end

  defp append_default(repo, set) do
    configuration = Configuration.default()
    {:ok, %{settings: settings}} = Configuration.validate(configuration)
    now = DateTime.utc_now()

    version = %Version{
      id: Ecto.UUID.generate(),
      set_id: set.id,
      origin: "system",
      configuration: configuration,
      settings: settings,
      inserted_at: now
    }

    {:ok, snapshot} = Snapshot.from_version(version)
    version = repo.insert!(%{version | checksum: snapshot.checksum})

    repo.insert!(%Activation{
      set_id: set.id,
      version_id: version.id,
      previous_version_id: set.active_version_id,
      operation: "bootstrap",
      revision: 2,
      inserted_at: now
    })

    repo.update!(Ecto.Changeset.change(set, active_version_id: version.id, revision: 2))
  end
end
