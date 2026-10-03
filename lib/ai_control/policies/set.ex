defmodule AiControl.Policies.Set do
  @moduledoc "One active pointer for either the platform or an organization."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "policy_sets" do
    field :organization_id, :binary_id
    field :active_version_id, :binary_id
    field :revision, :integer, default: 0
  end
end
