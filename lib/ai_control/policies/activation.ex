defmodule AiControl.Policies.Activation do
  @moduledoc "Append-only history; rollback reactivates an existing immutable version."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "policy_activations" do
    field :set_id, :binary_id
    field :version_id, :binary_id
    field :previous_version_id, :binary_id
    field :author_id, :binary_id
    field :operation, :string
    field :revision, :integer
    field :inserted_at, :utc_datetime_usec
  end
end
