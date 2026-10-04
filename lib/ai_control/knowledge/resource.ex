defmodule AiControl.Knowledge.Resource do
  @moduledoc "Only checked text is persisted. Ownership is supplied by verified adapters."
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Inspect, only: [:id, :organization_id, :kind, :revision]}
  schema "knowledge_resources" do
    belongs_to :organization, AiControl.Organizations.Organization
    belongs_to :owner_agent, AiControl.Agents.Agent
    field :creator_user_id, :binary_id
    field :creator_agent_id, :binary_id
    field :kind, :string
    field :origin, :string
    field :source_reference, :string, default: ""
    field :trust_level, :string, default: "untrusted"
    field :title, :string
    field :content, :string
    field :revision, :integer, default: 1
    field :policy_version, :string
    field :policy_checksum, :string
    field :checked_at, :utc_datetime_usec
    field :last_action, :string, default: "allow"
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(resource, attrs) do
    resource
    |> cast(attrs, [:title, :content, :source_reference, :trust_level])
    |> validate_required([:title, :content, :trust_level])
    |> validate_length(:title, max: 200)
    |> validate_length(:source_reference, max: 1000)
    |> validate_inclusion(:trust_level, ~w(untrusted internal))
    |> foreign_key_constraint(:owner_agent_id, name: :knowledge_owner_organization_fkey)
    |> check_constraint(:content, name: :knowledge_content_size)
  end
end
