defmodule AiControl.Approvals.Approval do
  @moduledoc "An immutable operation binding and one-use human authorization."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @derive {Inspect, only: [:id, :organization_id, :kind, :status, :revision]}
  schema "human_approvals" do
    field :organization_id, :binary_id
    field :actor_type, :string
    field :user_id, :binary_id
    field :agent_id, :binary_id
    field :api_key_id, :binary_id
    field :requester, :string
    field :kind, :string
    field :operation, :string
    field :model, :string
    field :target_agent_id, :binary_id
    field :run_id, :binary_id
    field :participant_id, :binary_id
    field :operation_request_id, :binary_id
    field :idempotency_key, :binary_id
    field :input_digest, :string
    field :prepared_digest, :string
    field :fingerprint_key_id, :string
    field :policy_version, :string
    field :policy_checksum, :string
    field :validated_policy_checksum, :string
    field :sources, {:array, :map}, default: []
    field :ciphertext, :binary
    field :encryption_key_id, :string
    field :status, :string, default: "pending"
    field :revision, :integer, default: 1
    field :approver_id, :binary_id
    field :claim_id, :binary_id
    field :claim_request_id, :binary_id
    field :expires_at, :utc_datetime_usec
    field :workflow_deadline, :utc_datetime_usec
    field :decided_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
