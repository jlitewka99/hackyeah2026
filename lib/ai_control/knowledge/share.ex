defmodule AiControl.Knowledge.Share do
  @moduledoc "Tenant-bound, read-only resource recipients."
  use Ecto.Schema

  @primary_key false
  schema "knowledge_shares" do
    field :organization_id, :binary_id, primary_key: true
    field :resource_id, :binary_id, primary_key: true
    field :agent_id, :binary_id, primary_key: true
  end
end
