defmodule AiControl.Repo.Migrations.CreateHumanApprovals do
  use Ecto.Migration

  def up do
    create table(:human_approvals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :restrict),
        null: false

      add :actor_type, :string, null: false
      add :user_id, :binary_id
      add :agent_id, :binary_id
      add :api_key_id, :binary_id
      add :requester, :string, null: false
      add :kind, :string, null: false
      add :operation, :string, null: false
      add :model, :string
      add :target_agent_id, :binary_id
      add :run_id, :binary_id
      add :participant_id, :binary_id
      add :operation_request_id, :binary_id, null: false
      add :idempotency_key, :binary_id, null: false
      add :input_digest, :string, null: false
      add :prepared_digest, :string, null: false
      add :fingerprint_key_id, :string, null: false
      add :policy_version, :string, null: false
      add :policy_checksum, :string, null: false
      add :validated_policy_checksum, :string
      add :sources, {:array, :map}, null: false, default: []
      add :ciphertext, :binary
      add :encryption_key_id, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :revision, :integer, null: false, default: 1
      add :approver_id, :binary_id
      add :claim_id, :binary_id
      add :claim_request_id, :binary_id
      add :expires_at, :utc_datetime_usec, null: false
      add :workflow_deadline, :utc_datetime_usec
      add :decided_at, :utc_datetime_usec
      add :consumed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:human_approvals, [:organization_id, :requester, :kind, :idempotency_key],
             name: :human_approvals_operation_key
           )

    create index(:human_approvals, [:organization_id, :status, :inserted_at, :id])
    create index(:human_approvals, [:organization_id, :run_id])

    create constraint(:human_approvals, :approval_status,
             check:
               "status IN ('pending','approved','claimed','consumed','rejected','expired','invalidated','uncertain')"
           )

    create constraint(:human_approvals, :approval_identity,
             check:
               "(actor_type = 'agent' AND api_key_id IS NOT NULL AND agent_id IS NOT NULL AND user_id IS NULL) OR (actor_type = 'user' AND user_id IS NOT NULL AND api_key_id IS NULL)"
           )

    create constraint(:human_approvals, :approval_kind,
             check: "kind IN ('tool','chat','delegation')"
           )

    create constraint(:human_approvals, :approval_revision, check: "revision > 0")

    drop constraint(:audit_events, :audit_decision_fields)

    create constraint(:audit_events, :audit_decision_fields,
             check: decision_fields("'allow','redact','block','review'")
           )

    drop constraint(:tool_executions, :tool_execution_status)
    drop constraint(:tool_executions, :tool_execution_charge)

    create constraint(:tool_executions, :tool_execution_status,
             check:
               "status IN ('pending','awaiting_review','dispatching','completed','rejected','output_blocked','failed','uncertain')"
           )

    create constraint(:tool_executions, :tool_execution_charge,
             check:
               "(status IN ('pending','awaiting_review','rejected') AND NOT charged) OR (status IN ('dispatching','completed','output_blocked','failed','uncertain') AND charged)"
           )

    drop constraint(:workflow_operations, :workflow_operation_status)

    create constraint(:workflow_operations, :workflow_operation_status,
             check:
               "status IN ('admitted','awaiting_review','dispatching','finished','uncertain')"
           )
  end

  def down do
    # Evidence must be exported/removed before downgrading the REVIEW contract.
    drop constraint(:audit_events, :audit_decision_fields)

    create constraint(:audit_events, :audit_decision_fields,
             check: decision_fields("'allow','redact','block'")
           )

    drop constraint(:tool_executions, :tool_execution_status)
    drop constraint(:tool_executions, :tool_execution_charge)

    create constraint(:tool_executions, :tool_execution_status,
             check:
               "status IN ('pending','dispatching','completed','rejected','output_blocked','failed','uncertain')"
           )

    create constraint(:tool_executions, :tool_execution_charge,
             check:
               "(status IN ('pending','rejected') AND NOT charged) OR (status IN ('dispatching','completed','output_blocked','failed','uncertain') AND charged)"
           )

    drop constraint(:workflow_operations, :workflow_operation_status)

    create constraint(:workflow_operations, :workflow_operation_status,
             check: "status IN ('admitted','dispatching','finished','uncertain')"
           )

    drop table(:human_approvals)
  end

  defp decision_fields(actions),
    do:
      "(kind = 'decision' AND stage IN ('input','output') AND action IN (#{actions}) AND action IS NOT NULL AND policy_version IS NOT NULL AND policy_checksum IS NOT NULL) OR (kind = 'administrative' AND stage = 'administrative' AND action IS NULL) OR (kind = 'gateway' AND stage IN ('input','output') AND action IS NULL AND ((policy_version IS NULL AND policy_checksum IS NULL) OR (policy_version IS NOT NULL AND policy_checksum IS NOT NULL)))"
end
