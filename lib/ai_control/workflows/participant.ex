defmodule AiControl.Workflows.Participant do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "workflow_participants" do
    field :organization_id, :binary_id
    field :run_id, :binary_id
    field :agent_id, :binary_id
    field :parent_id, :binary_id
    field :depth, :integer, default: 0
    field :idempotency_key, :binary_id
    field :inserted_at, :utc_datetime_usec
    field :name, :string, virtual: true
    field :parent_visible?, :boolean, virtual: true, default: false
  end
end
