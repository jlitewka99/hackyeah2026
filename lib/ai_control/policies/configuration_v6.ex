defmodule AiControl.Policies.ConfigurationV6 do
  @moduledoc "Explicit human review selectors; all pre-v6 policy contracts stay frozen."
  alias AiControl.Policies.ConfigurationV5
  alias AiControl.Tools.Catalog

  def defaults,
    do: %{"enabled" => false, "tools" => [], "llm_models" => [], "delegation_agents" => []}

  def validate(source) do
    review = Map.get(source, "review", %{})

    with true <- is_map(review) and not is_struct(review),
         true <- Enum.all?(Map.keys(review), &(&1 in Map.keys(defaults()))),
         settings = Map.merge(defaults(), review),
         true <- is_boolean(settings["enabled"]),
         true <- selectors?(settings["tools"], Enum.map(Catalog.all(), & &1["name"])),
         true <- names?(settings["llm_models"]),
         true <- agents?(settings["delegation_agents"]),
         base = source |> Map.delete("review") |> Map.put("schema_version", 5),
         {:ok, config} <- ConfigurationV5.validate(base) do
      {:ok,
       %{
         source: Map.merge(config.source, %{"schema_version" => 6, "review" => settings}),
         settings: Map.merge(config.settings, %{"schema_version" => 6, "review" => settings})
       }}
    else
      false ->
        {:error,
         [{"review", "choose an explicit switch and valid tool, model and agent selectors"}]}

      error ->
        error
    end
  end

  defp selectors?(items, allowed),
    do: is_list(items) and Enum.uniq(items) == items and Enum.all?(items, &(&1 in allowed))

  defp names?(items),
    do:
      is_list(items) and length(items) <= 500 and Enum.uniq(items) == items and
        ("*" not in items or items == ["*"]) and
        Enum.all?(items, &(is_binary(&1) and byte_size(&1) in 1..200))

  defp agents?(items),
    do:
      names?(items) and
        (items == ["*"] or Enum.all?(items, &match?({:ok, _}, Ecto.UUID.cast(&1))))
end
