defmodule AiControl.Policies.ConfigurationV5 do
  @moduledoc "Finite workflow limits, opt-in Knowledge and pinned NER rules; v1–v4 stay frozen."
  alias AiControl.Guards.{Feeds, Registry}
  alias AiControl.Policies.ConfigurationV4

  @workflow_defaults %{
    "tool_calls" => 25,
    "max_duration_seconds" => 300,
    "max_calls" => 50,
    "max_tokens" => 10_000,
    "max_delegation_depth" => 3,
    "max_repeated_actions" => 3
  }

  def workflow_defaults, do: @workflow_defaults

  def fields,
    do:
      ~w(tool_calls max_duration_seconds max_calls max_tokens max_delegation_depth max_repeated_actions)

  def defaults do
    %{
      "enabled" => false,
      "memory_write_enabled" => false,
      "sources" => ["document", "memory"],
      "trust_levels" => ["untrusted", "internal"]
    }
  end

  def validate(source) do
    with {:ok, limits} <- workflow(source),
         {:ok, sets} <- signature_sets(source),
         {:ok, knowledge, settings, model_set} <- knowledge(source),
         base =
           source
           |> Map.drop(["knowledge", "ner_model_set"])
           |> Map.put("schema_version", 4)
           |> Map.put("detector_sets", Registry.sets())
           |> put_in(["budgets", "workflow"], Map.take(limits, ["tool_calls"])),
         {:ok, config} <- ConfigurationV4.validate(base) do
      {:ok,
       %{
         source:
           config.source
           |> Map.merge(%{
             "schema_version" => 5,
             "detector_sets" => sets,
             "knowledge" => knowledge,
             "ner_model_set" => model_set
           })
           |> put_in(["budgets", "workflow"], limits),
         settings:
           config.settings
           |> Map.merge(%{
             "schema_version" => 5,
             "detector_sets" => sets,
             "knowledge" => settings,
             "ner_model_set" => model_set
           })
           |> put_in(["budgets", "workflow"], limits)
       }}
    end
  end

  defp workflow(source) do
    budgets = Map.get(source, "budgets", %{})
    workflow = if is_map(budgets), do: Map.get(budgets, "workflow", %{})

    with true <- is_map(workflow),
         true <- Enum.all?(Map.keys(workflow), &(&1 in fields())),
         limits = Map.merge(@workflow_defaults, workflow),
         true <- Enum.all?(limits, fn {_, v} -> is_integer(v) && v in 0..2_147_483_647 end),
         true <- limits["max_duration_seconds"] in 1..86_400,
         true <- limits["max_delegation_depth"] <= 32 do
      {:ok, limits}
    else
      _ ->
        {:error,
         [
           {"budgets.workflow",
            "use finite nonnegative integers, duration 1–86400 seconds and depth 0–32"}
         ]}
    end
  end

  defp knowledge(source) do
    knowledge = Map.get(source, "knowledge", %{})
    model_set = Map.get(source, "ner_model_set", "pl-nkjp.v2")

    with true <- is_map(knowledge) and not is_struct(knowledge),
         true <- Enum.all?(Map.keys(knowledge), &(&1 in Map.keys(defaults()))),
         settings = Map.merge(defaults(), knowledge),
         true <- is_boolean(settings["enabled"]) and is_boolean(settings["memory_write_enabled"]),
         true <- selected?(settings["sources"], ~w(document memory)),
         true <- selected?(settings["trust_levels"], ~w(untrusted internal)),
         true <- model_set in ~w(pl-nkjp.v1 pl-nkjp.v2) do
      {:ok, knowledge, settings, model_set}
    else
      _ ->
        {:error,
         [{"knowledge", "choose valid switches, source kinds, trust levels and NER model set"}]}
    end
  end

  defp signature_sets(source) do
    sets = Map.get(source, "detector_sets", Registry.sets())

    if is_map(sets) && map_size(sets) == map_size(Registry.sets()) &&
         Feeds.selector?(sets["signatures"]) &&
         Map.delete(sets, "signatures") == Map.delete(Registry.sets(), "signatures"),
       do: {:ok, sets},
       else: {:error, [{"detector_sets", "choose supported immutable detector sets"}]}
  end

  defp selected?(items, allowed),
    do:
      is_list(items) and items != [] and Enum.uniq(items) == items and
        Enum.all?(items, &(&1 in allowed))
end
