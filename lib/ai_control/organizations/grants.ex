defmodule AiControl.Organizations.Grants do
  @moduledoc "Individual capabilities and explicit agent/model selectors. Empty selectors deny access."
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @permissions ~w(ai.use agents.read agents.manage api_keys.read api_keys.manage policies.read policies.manage events.read events.export budgets.read budgets.manage signatures.read signatures.manage workflows.read workflows.manage)
  embedded_schema do
    field :permissions, {:array, :string}, default: []
    field :agents, {:array, :string}, default: []
    field :models, {:array, :string}, default: []
    field :all_agents, :boolean, virtual: true, default: false
    field :all_models, :boolean, virtual: true, default: false
    field :role, :string, virtual: true, default: "user"
  end

  def permissions, do: @permissions
  def full, do: %__MODULE__{permissions: @permissions, agents: ["*"], models: ["*"]}
  def attrs(%__MODULE__{} = grants), do: Map.take(grants, [:permissions, :agents, :models])
  def attrs(nil), do: attrs(%__MODULE__{})

  def changeset(grants, attrs) do
    grants
    |> cast(attrs, [:permissions, :agents, :models])
    |> validate_subset(:permissions, @permissions)
    |> validate_length(:permissions, max: length(@permissions))
    |> validate_length(:agents, max: 500)
    |> validate_length(:models, max: 500)
    |> validate_change(:agents, &validate_selectors/2)
    |> validate_change(:models, &validate_selectors/2)
  end

  def subset?(requested, allowed) do
    Enum.all?(requested.permissions, &(&1 in allowed.permissions)) &&
      selectors_subset?(requested.agents, allowed.agents) &&
      selectors_subset?(requested.models, allowed.models)
  end

  def selectors_subset?(requested, allowed),
    do: "*" in allowed || Enum.all?(requested, &(&1 in allowed))

  def includes?(selectors, key), do: "*" in selectors || key in selectors

  defp validate_selectors(field, selectors) do
    if Enum.all?(selectors, &(is_binary(&1) && byte_size(&1) in 1..200)) &&
         length(Enum.uniq(selectors)) == length(selectors) &&
         ("*" not in selectors || selectors == ["*"]) do
      []
    else
      [{field, "must contain unique resource identifiers or only *"}]
    end
  end
end
