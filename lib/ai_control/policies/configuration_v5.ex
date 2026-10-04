defmodule AiControl.Policies.ConfigurationV5 do
  @moduledoc "Opt-in Knowledge, snapshot-owned NER rules and immutable tenant signature selectors."
  alias AiControl.Guards.{Feeds, Registry}
  alias AiControl.Policies.ConfigurationV4

  def defaults do
    %{
      "enabled" => false,
      "memory_write_enabled" => false,
      "sources" => ["document", "memory"],
      "trust_levels" => ["untrusted", "internal"]
    }
  end

  def validate(source) do
    knowledge = Map.get(source, "knowledge", %{})
    model_set = Map.get(source, "ner_model_set", "pl-nkjp.v2")

    with {:ok, sets} <- signature_sets(source),
         true <- is_map(knowledge) and not is_struct(knowledge),
         true <- Enum.all?(Map.keys(knowledge), &(&1 in Map.keys(defaults()))),
         settings = Map.merge(defaults(), knowledge),
         true <- is_boolean(settings["enabled"]) and is_boolean(settings["memory_write_enabled"]),
         true <- selected?(settings["sources"], ~w(document memory)),
         true <- selected?(settings["trust_levels"], ~w(untrusted internal)),
         true <- model_set in ~w(pl-nkjp.v1 pl-nkjp.v2),
         base =
           source
           |> Map.drop(["knowledge", "ner_model_set"])
           |> Map.put("schema_version", 4)
           |> Map.put("detector_sets", Registry.sets()),
         {:ok, config} <- ConfigurationV4.validate(base) do
      {:ok,
       %{
         source:
           Map.merge(config.source, %{
             "schema_version" => 5,
             "detector_sets" => sets,
             "knowledge" => knowledge,
             "ner_model_set" => model_set
           }),
         settings:
           Map.merge(config.settings, %{
             "schema_version" => 5,
             "detector_sets" => sets,
             "knowledge" => settings,
             "ner_model_set" => model_set
           })
       }}
    else
      {:error, _} = error ->
        error

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
