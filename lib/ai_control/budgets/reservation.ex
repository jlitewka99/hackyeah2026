defmodule AiControl.Budgets.Reservation do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "budget_reservations" do
    field :organization_id, :binary_id
    field :agent_id, :binary_id
    field :request_id, :binary_id
    field :actor_type, :string
    field :user_id, :binary_id
    field :api_key_id, :binary_id
    field :window, :utc_datetime
    field :model, :string
    field :policy_version, :string
    field :policy_checksum, :string
    field :limits, :map
    field :policy_settings, :map
    field :status, :string, default: "admitted"
    field :reserved_tokens, :integer, default: 0
    field :input_tokens, :integer
    field :output_limit, :integer
    field :usage, :map
    field :price, :map
    field :cost, :decimal
    field :unbounded, :boolean, default: false
    field :overrun, :boolean, default: false
    field :dispatched_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
