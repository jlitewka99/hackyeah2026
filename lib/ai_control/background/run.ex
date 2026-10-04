defmodule AiControl.Background.Run do
  @moduledoc "Durable tenant-owned work. Specifications contain validated selectors, never payloads."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "background_runs" do
    field :organization_id, :binary_id
    field :user_id, :binary_id
    field :job_id, :integer
    field :kind, :string
    field :status, :string, default: "queued"
    field :dedup_key, :string
    field :permissions, {:array, :string}, default: []
    field :spec, :map, default: %{}
    field :result, :map, default: %{}
    field :progress, :integer, default: 0
    field :total, :integer, default: 0
    field :cursor, :integer, default: 0
    field :manifest_ready, :boolean, default: false
    field :checksum, :string
    field :error_code, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
