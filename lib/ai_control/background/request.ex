defmodule AiControl.Background.Request do
  @moduledoc "Form state for closed background selectors."
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :suite, :string, default: "gateway.v1"
    field :mode, :string, default: "controlled"
    field :kind, :string, default: "metrics_report"
    field :range, :string, default: "24h"
    field :include_budgets, :boolean, default: false
    field :package, :string
  end

  def changeset(attrs \\ %{}) do
    %__MODULE__{}
    |> cast(attrs, [:suite, :mode, :kind, :range, :include_budgets, :package])
    |> validate_inclusion(:suite, ~w(gateway.v1 semantic-pl.v1))
    |> validate_inclusion(:mode, ~w(controlled live))
    |> validate_inclusion(:kind, ~w(metrics_report audit_export audit_enrichment))
    |> validate_inclusion(:range, ~w(1h 24h 7d))
  end
end
