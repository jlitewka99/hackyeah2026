defmodule AiControl.Organizations.Membership do
  use Ecto.Schema

  import Ecto.Changeset

  alias AiControl.Organizations.Grants

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organization_memberships" do
    belongs_to :organization, AiControl.Organizations.Organization
    belongs_to :user, AiControl.Accounts.User
    field :role, Ecto.Enum, values: [:superadmin, :admin, :user], default: :user
    embeds_one :grants, Grants, on_replace: :update, defaults_to_struct: true
    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role])
    |> cast_embed(:grants, required: true)
    |> unique_constraint([:organization_id, :user_id])
    |> unique_constraint(:role, name: :one_organization_superadmin)
  end
end
