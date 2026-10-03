defmodule AiControl.Budgets.Workflow do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "budget_workflows" do
    field :organization_id, :binary_id
    field :agent_id, :binary_id
    field :workflow_id, :binary_id
    field :calls, :integer, default: 0
  end
end
