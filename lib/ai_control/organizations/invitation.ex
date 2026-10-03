defmodule AiControl.Organizations.Invitation do
  use Ecto.Schema

  import Ecto.Changeset

  alias AiControl.Accounts.User
  alias AiControl.Organizations.Grants

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organization_invitations" do
    belongs_to :organization, AiControl.Organizations.Organization
    belongs_to :invited_by, User
    field :email, :string
    field :role, Ecto.Enum, values: [:superadmin, :admin, :user]
    embeds_one :grants, Grants, on_replace: :update, defaults_to_struct: true
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime
    field :revoked_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email, :role])
    |> update_change(:email, &User.normalize_email/1)
    |> cast_embed(:grants, required: true)
    |> validate_required([:email, :role])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/)
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email, name: :one_pending_invitation_per_email)
  end

  def pending?(invitation, now \\ DateTime.utc_now(:second)) do
    is_nil(invitation.accepted_at) && is_nil(invitation.revoked_at) &&
      DateTime.after?(invitation.expires_at, now)
  end
end
