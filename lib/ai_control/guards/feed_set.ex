defmodule AiControl.Guards.FeedSet do
  @moduledoc "Immutable, content-addressed signature catalog owned by one organization."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "signature_sets" do
    field :organization_id, :binary_id
    field :set_id, :string
    field :checksum, :string
    field :version, :string
    field :origin, :string
    field :rules, :map
    field :inserted_at, :utc_datetime_usec
  end
end
