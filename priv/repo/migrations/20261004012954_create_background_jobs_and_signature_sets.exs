defmodule AiControl.Repo.Migrations.CreateBackgroundJobsAndSignatureSets do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)

    create table(:background_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :job_id, :bigint
      add :kind, :text, null: false
      add :status, :text, null: false, default: "queued"
      add :dedup_key, :text, null: false
      add :permissions, {:array, :text}, null: false
      add :spec, :map, null: false, default: %{}
      add :result, :map, null: false, default: %{}
      add :progress, :integer, null: false, default: 0
      add :total, :integer, null: false, default: 0
      add :cursor, :bigint, null: false, default: 0
      add :manifest_ready, :boolean, null: false, default: false
      add :checksum, :text
      add :error_code, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:background_runs, [:dedup_key],
             where: "status IN ('queued','running','retrying')"
           )

    create index(:background_runs, [:organization_id, :kind, :inserted_at])

    create table(:background_chunks, primary_key: false) do
      add :run_id, references(:background_runs, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :position, :bigint, primary_key: true
      add :data, :binary, null: false
    end

    create table(:background_export_events, primary_key: false) do
      add :run_id, references(:background_runs, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :position, :bigint, primary_key: true
      add :event_id, references(:audit_events, type: :binary_id), null: false
    end

    create unique_index(:background_export_events, [:run_id, :event_id])

    create table(:background_case_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:background_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :case_id, :text, null: false
      add :status, :text, null: false
      add :duration_us, :bigint, null: false
      add :evidence, :map, null: false, default: %{}
    end

    create unique_index(:background_case_results, [:run_id, :case_id])

    create table(:signature_sets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id), null: false
      add :set_id, :text, null: false
      add :checksum, :text, null: false
      add :version, :text, null: false
      add :origin, :text, null: false
      add :rules, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:signature_sets, [:organization_id, :set_id])
    create unique_index(:signature_sets, [:organization_id, :version])

    execute """
    CREATE FUNCTION immutable_signature_set() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'signature sets are immutable';
    END;
    $$ LANGUAGE plpgsql;
    """

    execute "CREATE TRIGGER immutable_signature_set BEFORE UPDATE OR DELETE ON signature_sets FOR EACH ROW EXECUTE FUNCTION immutable_signature_set()"
  end

  def down do
    drop table(:signature_sets)
    execute "DROP FUNCTION immutable_signature_set()"
    drop table(:background_case_results)
    drop table(:background_export_events)
    drop table(:background_chunks)
    drop table(:background_runs)
    Oban.Migration.down(version: 1)
  end
end
