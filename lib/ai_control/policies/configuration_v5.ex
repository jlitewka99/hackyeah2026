defmodule AiControl.Policies.ConfigurationV5 do
  @moduledoc "Opt-in Knowledge controls and a snapshot-owned NER rule version."
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

    with true <- is_map(knowledge) and not is_struct(knowledge),
         true <- Enum.all?(Map.keys(knowledge), &(&1 in Map.keys(defaults()))),
         settings = Map.merge(defaults(), knowledge),
         true <- is_boolean(settings["enabled"]) and is_boolean(settings["memory_write_enabled"]),
         true <- selected?(settings["sources"], ~w(document memory)),
         true <- selected?(settings["trust_levels"], ~w(untrusted internal)),
         true <- model_set in ~w(pl-nkjp.v1 pl-nkjp.v2),
         base = source |> Map.drop(["knowledge", "ner_model_set"]) |> Map.put("schema_version", 4),
         {:ok, config} <- ConfigurationV4.validate(base) do
      {:ok,
       %{
         source:
           Map.merge(config.source, %{
             "schema_version" => 5,
             "knowledge" => knowledge,
             "ner_model_set" => model_set
           }),
         settings:
           Map.merge(config.settings, %{
             "schema_version" => 5,
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

  defp selected?(items, allowed),
    do:
      is_list(items) and items != [] and Enum.uniq(items) == items and
        Enum.all?(items, &(&1 in allowed))
end
