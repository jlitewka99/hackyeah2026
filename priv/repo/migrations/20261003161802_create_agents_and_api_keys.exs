defmodule AiControl.Repo.Migrations.CreateAgentsAndApiKeys do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :status, :string, null: false, default: "active"
      timestamps(type: :utc_datetime)
    end

    create index(:agents, [:organization_id])
    create unique_index(:agents, [:id, :organization_id])
    create constraint(:agents, :agent_status, check: "status IN ('active', 'suspended')")

    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id,
          references(:agents,
            type: :binary_id,
            with: [organization_id: :organization_id],
            on_delete: :delete_all
          ),
          null: false

      add :label, :string, null: false
      add :token_hash, :binary, null: false
      add :prefix, :string, null: false
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:api_keys, [:organization_id, :agent_id])
    create unique_index(:api_keys, [:token_hash])
  end
end
