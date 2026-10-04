defmodule AiControl.Background.ExportEvent do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "background_export_events" do
    field :run_id, :binary_id, primary_key: true
    field :position, :integer, primary_key: true
    field :event_id, :binary_id
  end
end
