defmodule AiControl.Repo.Migrations.CreateWorkflowRuns do
  use Ecto.Migration

  def change do
    create table(:workflow_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :owner_agent_id, references(:agents, type: :binary_id), null: false
      add :api_key_id, :binary_id, null: false
      add :idempotency_key, :binary_id, null: false
      add :goal, :string, size: 240, null: false
      add :goal_digest, :string, null: false
      add :fingerprint_key_id, :string, null: false
      add :policy_version, :string, null: false
      add :limits, :map, null: false
      add :calls, :bigint, default: 0, null: false
      add :tokens, :bigint, default: 0, null: false
      add :reserved_tokens, :bigint, default: 0, null: false
      add :status, :string, default: "running", null: false
      add :reason, :string
      add :started_at, :utc_datetime_usec, null: false
      add :deadline, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
    end

    create unique_index(:workflow_runs, [:organization_id, :owner_agent_id, :idempotency_key])
    create index(:workflow_runs, [:organization_id, :started_at, :id])

    create constraint(:workflow_runs, :workflow_counters_nonnegative,
             check: "calls >= 0 AND tokens >= 0 AND reserved_tokens >= 0"
           )

    create constraint(:workflow_runs, :workflow_status,
             check:
               "status IN ('running', 'completed', 'stopped', 'limit_exceeded', 'interrupted')"
           )

    create table(:workflow_participants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:workflow_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, type: :binary_id), null: false
      add :parent_id, references(:workflow_participants, type: :binary_id, on_delete: :delete_all)
      add :depth, :integer, null: false
      add :idempotency_key, :binary_id
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:workflow_participants, [:run_id, :parent_id, :idempotency_key])
    create index(:workflow_participants, [:organization_id, :run_id, :agent_id])
    create constraint(:workflow_participants, :workflow_depth, check: "depth BETWEEN 0 AND 32")

    create table(:workflow_operations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:workflow_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :participant_id, references(:workflow_participants, type: :binary_id), null: false
      add :request_id, :binary_id, null: false
      add :kind, :string, null: false
      add :fingerprint_digest, :string, null: false
      add :fingerprint_key_id, :string, null: false
      add :status, :string, default: "admitted", null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:workflow_operations, [:organization_id, :request_id])
    create index(:workflow_operations, [:run_id, :fingerprint_key_id, :fingerprint_digest])

    create constraint(:workflow_operations, :workflow_operation_kind,
             check: "kind IN ('chat', 'tool', 'delegation')"
           )

    create constraint(:workflow_operations, :workflow_operation_status,
             check: "status IN ('admitted', 'dispatching', 'finished', 'uncertain')"
           )

    for table <- [:budget_reservations, :tool_executions, :audit_events] do
      alter table(table) do
        add :run_id, :binary_id
        add :participant_id, :binary_id
      end

      create index(table, [:organization_id, :run_id])
    end
  end
end
