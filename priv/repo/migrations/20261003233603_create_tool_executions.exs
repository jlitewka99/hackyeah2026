defmodule AiControl.Repo.Migrations.CreateToolExecutions do
  use Ecto.Migration

  def change do
    create table(:tool_executions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id,
          references(:agents,
            type: :binary_id,
            with: [organization_id: :organization_id],
            on_delete: :delete_all
          ), null: false

      add :api_key_id, :binary_id, null: false
      add :request_id, :binary_id, null: false
      add :workflow_id, :binary_id, null: false
      add :idempotency_key, :binary_id, null: false
      add :fingerprint_digest, :string, null: false
      add :fingerprint_key_id, :string, null: false
      add :tool, :string, null: false
      add :policy_version, :string, null: false
      add :policy_checksum, :string, null: false
      add :policy_settings, :map, null: false
      add :status, :string, null: false, default: "pending"
      add :charged, :boolean, null: false, default: false
      add :code, :string
      add :dispatched_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tool_executions, [:organization_id, :agent_id, :idempotency_key])
    create index(:tool_executions, [:organization_id, :request_id])

    create constraint(:tool_executions, :tool_execution_status,
             check:
               "status IN ('pending','dispatching','completed','rejected','output_blocked','failed','uncertain')"
           )

    create constraint(:tool_executions, :tool_execution_charge,
             check:
               "(status IN ('pending','rejected') AND NOT charged) OR (status IN ('dispatching','completed','output_blocked','failed','uncertain') AND charged)"
           )
  end
end
