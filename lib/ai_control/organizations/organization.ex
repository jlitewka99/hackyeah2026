defmodule AiControl.Organizations.Organization do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "organizations" do
    field :name, :string
    field :status, Ecto.Enum, values: [:active, :suspended], default: :active
    timestamps(type: :utc_datetime)
  end

  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 120)
  end
end
