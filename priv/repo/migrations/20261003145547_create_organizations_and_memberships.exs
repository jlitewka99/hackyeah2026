defmodule AiControl.Repo.Migrations.CreateOrganizationsAndMemberships do
  use Ecto.Migration

  def change do
    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :status, :string, null: false, default: "active"
      timestamps(type: :utc_datetime)
    end

    create constraint(:organizations, :organization_status,
             check: "status IN ('active', 'suspended')"
           )

    create table(:organization_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :role, :string, null: false, default: "user"
      add :grants, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:organization_memberships, [:organization_id, :user_id])
    create index(:organization_memberships, [:user_id])

    create unique_index(:organization_memberships, [:organization_id],
             where: "role = 'superadmin'",
             name: :one_organization_superadmin
           )

    create constraint(:organization_memberships, :membership_role,
             check: "role IN ('superadmin', 'admin', 'user')"
           )

    create table(:organization_invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :invited_by_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :email, :citext, null: false
      add :role, :string, null: false
      add :grants, :map, null: false, default: %{}
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :accepted_at, :utc_datetime
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:organization_invitations, [:token_hash])
    create index(:organization_invitations, [:organization_id])

    create unique_index(:organization_invitations, [:organization_id, :email],
             where: "accepted_at IS NULL AND revoked_at IS NULL",
             name: :one_pending_invitation_per_email
           )

    create constraint(:organization_invitations, :invitation_role,
             check: "role IN ('superadmin', 'admin', 'user')"
           )
  end
end
