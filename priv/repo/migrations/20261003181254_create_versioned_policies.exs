defmodule AiControl.Repo.Migrations.CreateVersionedPolicies do
  use Ecto.Migration

  def up do
    create table(:policy_sets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all)
      add :active_version_id, :binary_id
      add :revision, :bigint, null: false, default: 0
    end

    create unique_index(:policy_sets, [:organization_id])

    create unique_index(:policy_sets, ["(1)"],
             where: "organization_id IS NULL",
             name: :one_global_policy_set
           )

    create constraint(:policy_sets, :policy_revision_nonnegative, check: "revision >= 0")

    create table(:policy_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :set_id, references(:policy_sets, type: :binary_id, on_delete: :restrict), null: false
      add :author_id, :binary_id
      add :origin, :string, null: false
      add :configuration, :map, null: false
      add :settings, :map, null: false
      add :checksum, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:policy_versions, [:set_id, :id])
    create index(:policy_versions, [:set_id, :inserted_at])

    create constraint(:policy_versions, :policy_version_author,
             check:
               "(origin = 'system' AND author_id IS NULL) OR (origin = 'user' AND author_id IS NOT NULL)"
           )

    execute "ALTER TABLE policy_sets ADD CONSTRAINT policy_active_version_owner FOREIGN KEY (id, active_version_id) REFERENCES policy_versions(set_id, id)"

    create table(:policy_activations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :set_id, references(:policy_sets, type: :binary_id, on_delete: :restrict), null: false
      add :version_id, :binary_id
      add :previous_version_id, :binary_id
      add :author_id, :binary_id
      add :operation, :string, null: false
      add :revision, :bigint, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:policy_activations, [:set_id, :revision])

    execute "ALTER TABLE policy_activations ADD CONSTRAINT policy_activation_version_owner FOREIGN KEY (set_id, version_id) REFERENCES policy_versions(set_id, id)"

    execute "ALTER TABLE policy_activations ADD CONSTRAINT policy_previous_version_owner FOREIGN KEY (set_id, previous_version_id) REFERENCES policy_versions(set_id, id)"

    execute "CREATE FUNCTION reject_policy_update() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'Policy records are immutable'; END $$"

    execute "CREATE TRIGGER immutable_policy_version BEFORE UPDATE ON policy_versions FOR EACH ROW EXECUTE FUNCTION reject_policy_update()"

    execute "CREATE TRIGGER immutable_policy_activation BEFORE UPDATE ON policy_activations FOR EACH ROW EXECUTE FUNCTION reject_policy_update()"

    alter table(:audit_events) do
      modify :organization_id, :binary_id, null: true
      add :scope, :string, null: false, default: "organization"
    end

    create constraint(:audit_events, :audit_scope_identity,
             check:
               "(scope = 'organization' AND organization_id IS NOT NULL) OR (scope = 'platform' AND organization_id IS NULL AND kind = 'administrative' AND actor_type = 'user' AND event_type IN ('policy.version_created', 'policy.activated', 'policy.rolled_back'))"
           )

    flush()
    seed_default()

    execute "INSERT INTO policy_sets (id, organization_id, revision) SELECT gen_random_uuid(), id, 0 FROM organizations"
  end

  def down do
    drop constraint(:audit_events, :audit_scope_identity)
    execute "DELETE FROM audit_events WHERE scope = 'platform'"

    alter table(:audit_events) do
      remove :scope
      modify :organization_id, :binary_id, null: false
    end

    execute "ALTER TABLE policy_sets DROP CONSTRAINT policy_active_version_owner"
    drop table(:policy_activations)
    drop table(:policy_versions)
    drop table(:policy_sets)
    execute "DROP FUNCTION reject_policy_update()"
  end

  defp seed_default do
    # Pin initial semantics here; later profile defaults must not rewrite this version.
    configuration = %{
      "schema_version" => 1,
      "profile" => "balanced",
      "allowed_models" => ["qwen3.5:4b"],
      "allowed_agents" => ["*"],
      "agent_models" => %{},
      "budgets" => %{},
      "rules" => %{},
      "guards" => %{}
    }

    rules =
      Map.new(~w(pii secret exploit prompt_injection), fn category ->
        {category,
         %{
           "id" => "#{category}.default",
           "action" => if(category == "pii", do: "redact", else: "block"),
           "threshold" => if(category == "prompt_injection", do: 0.8, else: 0)
         }}
      end)

    guards =
      Map.new(~w(pii secret signatures semantic), fn guard ->
        {guard,
         %{
           "enabled" => true,
           "required" => true,
           "stages" => if(guard == "semantic", do: ["input"], else: ["input", "output"])
         }}
      end)

    budgets = %{
      "organization" => %{"requests_per_hour" => nil, "tokens_per_hour" => nil},
      "agent" => %{"requests_per_hour" => nil, "tokens_per_hour" => nil},
      "workflow" => %{"tool_calls" => nil}
    }

    settings =
      configuration
      |> Map.put("rules", rules)
      |> Map.put("guards", guards)
      |> Map.put("budgets", budgets)

    set = repo().insert!(%AiControl.Policies.Set{})

    version = %AiControl.Policies.Version{
      id: Ecto.UUID.generate(),
      set_id: set.id,
      origin: "system",
      configuration: configuration,
      settings: settings,
      inserted_at: DateTime.utc_now()
    }

    {:ok, snapshot} = AiControl.Policy.Snapshot.from_version(version)
    version = repo().insert!(%{version | checksum: snapshot.checksum})
    repo().update!(Ecto.Changeset.change(set, active_version_id: version.id, revision: 1))

    repo().insert!(%AiControl.Policies.Activation{
      set_id: set.id,
      version_id: version.id,
      operation: "bootstrap",
      revision: 1,
      inserted_at: DateTime.utc_now()
    })
  end
end
