defmodule AiControl.Policies.ConfigurationV5 do
  @moduledoc "Extends v4 with an immutable signature selector; legacy validation remains frozen."
  alias AiControl.Guards.{Feeds, Registry}
  alias AiControl.Policies.ConfigurationV4

  def validate(source) do
    sets = Map.get(source, "detector_sets", Registry.sets())

    with true <- is_map(sets) && map_size(sets) == map_size(Registry.sets()),
         true <- Feeds.selector?(sets["signatures"]),
         true <- Map.delete(sets, "signatures") == Map.delete(Registry.sets(), "signatures"),
         {:ok, config} <-
           source
           |> Map.put("schema_version", 4)
           |> Map.put("detector_sets", Registry.sets())
           |> ConfigurationV4.validate() do
      {:ok,
       %{
         source: config.source |> Map.put("schema_version", 5) |> Map.put("detector_sets", sets),
         settings:
           config.settings |> Map.put("schema_version", 5) |> Map.put("detector_sets", sets)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, [{"detector_sets", "choose supported immutable detector sets"}]}
    end
  end
end
