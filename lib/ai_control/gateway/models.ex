defmodule AiControl.Gateway.Models do
  @moduledoc "Validated operator catalog shared by authorization and delegation."
  alias AiControl.Gateway.Config
  alias AiControl.Organizations
  alias AiControl.Organizations.Grants

  def all, do: Config.get(:models) |> Map.keys() |> Enum.sort()
  def registered?(name), do: Map.has_key?(Config.get(:models), name)

  def list_assignable(scope) do
    with {:ok, current} <- Organizations.refresh_scope(scope),
         :ok <- Organizations.require_manager(current) do
      {:ok, Enum.filter(all(), &Grants.includes?(current.grants.models, &1))}
    end
  end
end
