defmodule AiControl.Budgets.ToolExecution do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "budget_tool_executions" do
    field :workflow_id, :binary_id
    field :execution_id, :binary_id
  end
end
