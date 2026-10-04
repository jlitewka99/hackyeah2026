defmodule AiControl.Repo.Migrations.CreateKnowledgeResources do
  use Ecto.Migration

  def change do
    create table(:knowledge_resources, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :owner_agent_id,
          references(:agents,
            type: :binary_id,
            with: [organization_id: :organization_id],
            name: :knowledge_owner_organization_fkey,
            on_delete: :delete_all
          ),
          null: false

      add :creator_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :creator_agent_id,
          references(:agents,
            type: :binary_id,
            with: [organization_id: :organization_id],
            on_delete: :nothing
          )

      add :kind, :string, null: false
      add :origin, :string, null: false
      add :source_reference, :text, null: false, default: ""
      add :trust_level, :string, null: false, default: "untrusted"
      add :title, :string, null: false
      add :content, :text, null: false
      add :revision, :integer, null: false, default: 1
      add :policy_version, :string, null: false
      add :policy_checksum, :string, null: false
      add :checked_at, :utc_datetime_usec, null: false
      add :last_action, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:knowledge_resources, [:id, :organization_id])
    create index(:knowledge_resources, [:organization_id, :owner_agent_id, :kind])

    create constraint(:knowledge_resources, :knowledge_kind,
             check: "kind IN ('document', 'memory')"
           )

    create constraint(:knowledge_resources, :knowledge_trust,
             check: "trust_level IN ('untrusted', 'internal')"
           )

    create constraint(:knowledge_resources, :knowledge_origin,
             check: "origin IN ('manual', 'upload', 'api', 'agent')"
           )

    create constraint(:knowledge_resources, :knowledge_revision, check: "revision > 0")

    create constraint(:knowledge_resources, :knowledge_content_size,
             check:
               "octet_length(content) BETWEEN 1 AND CASE WHEN kind = 'memory' THEN 16384 ELSE 65536 END"
           )

    create constraint(:knowledge_resources, :knowledge_action,
             check: "last_action IN ('allow', 'redact')"
           )

    execute(
      "CREATE INDEX knowledge_search_idx ON knowledge_resources USING GIN (to_tsvector('simple', title || ' ' || content))",
      "DROP INDEX knowledge_search_idx"
    )

    create table(:knowledge_shares, primary_key: false) do
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :resource_id,
          references(:knowledge_resources,
            type: :binary_id,
            with: [organization_id: :organization_id],
            on_delete: :delete_all
          ),
          primary_key: true

      add :agent_id,
          references(:agents,
            type: :binary_id,
            with: [organization_id: :organization_id],
            on_delete: :delete_all
          ),
          primary_key: true
    end

    create index(:knowledge_shares, [:organization_id, :agent_id])
  end
end
