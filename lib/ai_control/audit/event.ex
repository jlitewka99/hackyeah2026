defmodule AiControl.Audit.Event do
  @moduledoc "Persisted content-free security and administrative evidence."
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @fields [
    :organization_id,
    :actor_type,
    :user_id,
    :agent_id,
    :api_key_id,
    :request_id,
    :kind,
    :event_type,
    :target_id,
    :stage,
    :action,
    :policy_version,
    :policy_checksum,
    :rule_ids,
    :reason_codes,
    :fingerprint_digest,
    :fingerprint_key_id,
    :occurred_at,
    :duration_us,
    :data
  ]

  schema "audit_events" do
    field :organization_id, :binary_id
    field :actor_type, Ecto.Enum, values: [:user, :agent]
    field :user_id, :binary_id
    field :agent_id, :binary_id
    field :api_key_id, :binary_id
    field :request_id, :binary_id
    field :kind, Ecto.Enum, values: [:decision, :administrative]
    field :event_type, :string
    field :target_id, :binary_id
    field :stage, Ecto.Enum, values: [:input, :output, :administrative]
    field :action, Ecto.Enum, values: [:allow, :redact, :block]
    field :policy_version, :string
    field :policy_checksum, :string
    field :rule_ids, {:array, :string}, default: []
    field :reason_codes, {:array, :string}, default: []
    field :fingerprint_digest, :string
    field :fingerprint_key_id, :string
    field :occurred_at, :utc_datetime_usec
    field :duration_us, :integer, default: 0
    field :data, :map, default: %{}
  end

  def fields, do: [:id | @fields]

  def changeset(event) do
    event
    |> change()
    |> validate_required([
      :organization_id,
      :actor_type,
      :request_id,
      :kind,
      :event_type,
      :target_id,
      :stage,
      :occurred_at,
      :duration_us
    ])
    |> validate_number(:duration_us, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:organization_id)
  end
end
