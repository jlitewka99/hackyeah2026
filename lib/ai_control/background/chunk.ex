defmodule AiControl.Background.Chunk do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "background_chunks" do
    field :run_id, :binary_id, primary_key: true
    field :position, :integer, primary_key: true
    field :data, :binary
  end
end
