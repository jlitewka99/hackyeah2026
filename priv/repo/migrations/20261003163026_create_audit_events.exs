defmodule AiControl.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :restrict),
        null: false

      add :actor_type, :string, null: false
      add :user_id, :binary_id
      add :agent_id, :binary_id
      add :api_key_id, :binary_id
      add :request_id, :binary_id, null: false
      add :kind, :string, null: false
      add :event_type, :string, null: false
      add :target_id, :binary_id, null: false
      add :stage, :string, null: false
      add :action, :string
      add :policy_version, :string
      add :policy_checksum, :string
      add :rule_ids, {:array, :string}, null: false, default: []
      add :reason_codes, {:array, :string}, null: false, default: []
      add :fingerprint_digest, :string
      add :fingerprint_key_id, :string
      add :occurred_at, :utc_datetime_usec, null: false
      add :duration_us, :bigint, null: false, default: 0
      add :data, :map, null: false, default: %{}
    end

    create index(:audit_events, [:organization_id, :occurred_at, :id])
    create index(:audit_events, [:organization_id, :request_id])

    create constraint(:audit_events, :audit_event_kind,
             check: "kind IN ('decision', 'administrative')"
           )

    create constraint(:audit_events, :audit_actor_identity,
             check:
               "(actor_type = 'user' AND user_id IS NOT NULL AND agent_id IS NULL AND api_key_id IS NULL) OR (actor_type = 'agent' AND user_id IS NULL AND agent_id IS NOT NULL AND api_key_id IS NOT NULL)"
           )

    create constraint(:audit_events, :audit_duration_nonnegative, check: "duration_us >= 0")

    create constraint(:audit_events, :audit_decision_fields,
             check:
               "(kind = 'decision' AND stage IN ('input', 'output') AND action IS NOT NULL AND action IN ('allow', 'redact', 'block') AND policy_version IS NOT NULL AND policy_checksum IS NOT NULL) OR (kind = 'administrative' AND stage = 'administrative' AND action IS NULL)"
           )
  end
end
