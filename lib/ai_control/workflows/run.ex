defmodule AiControl.Workflows.Run do
  @moduledoc false
  use Ecto.Schema

  @derive {Inspect, only: [:id, :organization_id, :status, :reason]}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "workflow_runs" do
    field :organization_id, :binary_id
    field :owner_agent_id, :binary_id
    field :api_key_id, :binary_id
    field :idempotency_key, :binary_id
    field :goal, :string
    field :goal_digest, :string
    field :fingerprint_key_id, :string
    field :policy_version, :string
    field :limits, :map
    field :calls, :integer, default: 0
    field :tokens, :integer, default: 0
    field :reserved_tokens, :integer, default: 0
    field :status, :string, default: "running"
    field :reason, :string
    field :started_at, :utc_datetime_usec
    field :deadline, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
  end
end
