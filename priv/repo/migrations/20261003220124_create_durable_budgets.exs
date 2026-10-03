defmodule AiControl.Repo.Migrations.CreateDurableBudgets do
  use Ecto.Migration

  def change do
    create table(:budget_buckets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :level, :string, null: false
      add :subject_id, :binary_id, null: false
      add :window, :utc_datetime, null: false
      add :requests, :bigint, null: false, default: 0
      add :tokens, :bigint, null: false, default: 0
      add :reserved, :bigint, null: false, default: 0
      add :unbounded, :bigint, null: false, default: 0
    end

    create unique_index(:budget_buckets, [:organization_id, :level, :subject_id, :window])

    create constraint(:budget_buckets, :budget_nonnegative,
             check: "requests >= 0 AND tokens >= 0 AND reserved >= 0 AND unbounded >= 0"
           )

    create constraint(:budget_buckets, :budget_level, check: "level IN ('organization', 'agent')")

    create table(:budget_reservations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id,
          references(:agents,
            type: :binary_id,
            with: [organization_id: :organization_id],
            on_delete: :delete_all
          ),
          null: false

      add :request_id, :binary_id, null: false
      add :actor_type, :string, null: false
      add :user_id, :binary_id
      add :api_key_id, :binary_id
      add :window, :utc_datetime, null: false
      add :model, :string, null: false
      add :policy_version, :string, null: false
      add :policy_checksum, :string, null: false
      add :limits, :map, null: false
      add :policy_settings, :map, null: false
      add :status, :string, null: false, default: "admitted"
      add :reserved_tokens, :bigint, null: false, default: 0
      add :input_tokens, :bigint
      add :output_limit, :bigint
      add :usage, :map
      add :price, :map
      add :cost, :decimal, precision: 30, scale: 12
      add :unbounded, :boolean, null: false, default: false
      add :overrun, :boolean, null: false, default: false
      add :dispatched_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:budget_reservations, [:organization_id, :request_id])
    create index(:budget_reservations, [:organization_id, :window, :status])

    create constraint(:budget_reservations, :reservation_actor,
             check:
               "(actor_type = 'user' AND user_id IS NOT NULL AND api_key_id IS NULL) OR (actor_type = 'agent' AND api_key_id IS NOT NULL AND user_id IS NULL)"
           )

    create constraint(:budget_reservations, :reservation_status,
             check:
               "status IN ('admitted', 'reserved', 'dispatching', 'uncertain', 'settled', 'released')"
           )

    create constraint(:budget_reservations, :reservation_nonnegative,
             check:
               "reserved_tokens >= 0 AND (input_tokens IS NULL OR input_tokens >= 0) AND (output_limit IS NULL OR output_limit > 0)"
           )

    create table(:budget_workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id,
          references(:agents,
            type: :binary_id,
            with: [organization_id: :organization_id],
            on_delete: :delete_all
          ),
          null: false

      add :workflow_id, :binary_id, null: false
      add :calls, :bigint, null: false, default: 0
    end

    create unique_index(:budget_workflows, [:organization_id, :workflow_id])
    create constraint(:budget_workflows, :workflow_nonnegative, check: "calls >= 0")

    create table(:budget_tool_executions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_id, references(:budget_workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :execution_id, :binary_id, null: false
    end

    create unique_index(:budget_tool_executions, [:workflow_id, :execution_id])
  end
end
