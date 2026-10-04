defmodule AiControl.Workflows.Operation do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "workflow_operations" do
    field :organization_id, :binary_id
    field :run_id, :binary_id
    field :participant_id, :binary_id
    field :request_id, :binary_id
    field :kind, :string
    field :fingerprint_digest, :string
    field :fingerprint_key_id, :string
    field :status, :string, default: "admitted"
    field :inserted_at, :utc_datetime_usec
  end
end
