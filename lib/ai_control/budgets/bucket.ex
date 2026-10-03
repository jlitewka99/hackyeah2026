defmodule AiControl.Budgets.Bucket do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "budget_buckets" do
    field :organization_id, :binary_id
    field :level, :string
    field :subject_id, :binary_id
    field :window, :utc_datetime
    field :requests, :integer, default: 0
    field :tokens, :integer, default: 0
    field :reserved, :integer, default: 0
    field :unbounded, :integer, default: 0
  end
end
