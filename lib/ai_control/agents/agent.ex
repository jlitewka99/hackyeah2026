defmodule AiControl.Agents.Agent do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agents" do
    field :name, :string
    field :status, Ecto.Enum, values: [:active, :suspended], default: :active
    belongs_to :organization, AiControl.Organizations.Organization
    timestamps(type: :utc_datetime)
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 120)
  end
end
