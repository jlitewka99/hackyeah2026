defmodule AiControl.Policies.ConfigurationV5 do
  @moduledoc "Finite root workflow limits; v1–v4 authoring and checksums remain frozen."
  alias AiControl.Policies.ConfigurationV4

  @defaults %{
    "tool_calls" => 25,
    "max_duration_seconds" => 300,
    "max_calls" => 50,
    "max_tokens" => 10_000,
    "max_delegation_depth" => 3,
    "max_repeated_actions" => 3
  }
  def defaults, do: @defaults

  def fields,
    do:
      ~w(tool_calls max_duration_seconds max_calls max_tokens max_delegation_depth max_repeated_actions)

  def validate(source) do
    budgets = Map.get(source, "budgets", %{})
    workflow = if is_map(budgets), do: Map.get(budgets, "workflow", %{})

    with true <- is_map(workflow),
         true <- Enum.all?(Map.keys(workflow), &(&1 in fields())),
         limits = Map.merge(@defaults, workflow),
         true <- Enum.all?(limits, fn {_, v} -> is_integer(v) && v in 0..2_147_483_647 end),
         true <- limits["max_duration_seconds"] in 1..86_400,
         true <- limits["max_delegation_depth"] <= 32,
         base =
           source
           |> Map.put("schema_version", 4)
           |> put_in(["budgets", "workflow"], Map.take(limits, ["tool_calls"])),
         {:ok, config} <- ConfigurationV4.validate(base) do
      {:ok,
       %{
         source:
           config.source
           |> Map.put("schema_version", 5)
           |> put_in(["budgets", "workflow"], limits),
         settings:
           config.settings
           |> Map.put("schema_version", 5)
           |> put_in(["budgets", "workflow"], limits)
       }}
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         [
           {"budgets.workflow",
            "use finite nonnegative integers, duration 1–86400 seconds and depth 0–32"}
         ]}
    end
  end
end
