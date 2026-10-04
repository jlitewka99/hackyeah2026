defmodule AiControl.Tools.Execution do
  @moduledoc "Content-free durable execution receipt; no automatic replay."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @derive {Inspect, only: [:id, :organization_id, :agent_id, :tool, :status]}
  schema "tool_executions" do
    field :organization_id, :binary_id
    field :agent_id, :binary_id
    field :api_key_id, :binary_id
    field :request_id, :binary_id
    field :workflow_id, :binary_id
    field :idempotency_key, :binary_id
    field :fingerprint_digest, :string
    field :fingerprint_key_id, :string
    field :tool, :string
    field :policy_version, :string
    field :policy_checksum, :string
    field :policy_settings, :map
    field :status, :string, default: "pending"
    field :charged, :boolean, default: false
    field :code, :string
    field :dispatched_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
