defmodule AiControl.Background.CaseResult do
  @moduledoc "Closed, content-free scenario evidence."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "background_case_results" do
    field :run_id, :binary_id
    field :case_id, :string
    field :status, :string
    field :duration_us, :integer
    field :evidence, :map, default: %{}
  end
end
