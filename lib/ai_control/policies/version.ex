defmodule AiControl.Policies.Version do
  @moduledoc "Immutable source configuration and resolved enforcement snapshot."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "policy_versions" do
    field :set_id, :binary_id
    field :author_id, :binary_id
    field :origin, :string, default: "user"
    field :configuration, :map
    field :settings, :map
    field :checksum, :string
    field :inserted_at, :utc_datetime_usec
  end
end
