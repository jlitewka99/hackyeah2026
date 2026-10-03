defmodule AiControl.Policies.ConfigurationV3 do
  @moduledoc "Explicit label mapping and optional output moderation without changing v1/v2."
  alias AiControl.Policies.{Configuration, ConfigurationV2}
  alias AiControl.Security.Validation

  def validate(source) do
    rules = Map.get(source, "rules", %{})
    guards = Map.get(source, "guards", %{})

    if is_map(rules) && is_map(guards),
      do: validate_mappings(source, rules, guards),
      else: {:error, [{"policy", "rules and guards must be mappings"}]}
  end

  defp validate_mappings(source, rules, guards) do
    base =
      source
      |> Map.put("schema_version", 2)
      |> Map.put("rules", Map.delete(rules, "content_safety"))
      |> Map.put("guards", legacy_guards(guards))

    with {:ok, config} <- ConfigurationV2.validate(base),
         [] <- errors(rules, guards) do
      profile = source["profile"]
      severities = if profile == "strict", do: Configuration.severities(), else: ["Unsafe"]

      semantic =
        Map.put(config.settings["guards"]["semantic"], "severities", severities)
        |> Map.merge(Map.get(guards, "semantic", %{}))

      moderation =
        Map.merge(
          %{
            "enabled" => false,
            "required" => false,
            "stages" => ["output"],
            "severities" => severities,
            "categories" => Configuration.safety_categories()
          },
          Map.get(guards, "moderation", %{})
        )

      safety =
        Map.merge(
          %{"id" => "content_safety.default", "action" => "block", "threshold" => 0},
          Map.get(rules, "content_safety", %{})
        )

      settings =
        config.settings
        |> Map.put("schema_version", 3)
        |> put_in(["rules", "prompt_injection", "threshold"], 0)
        |> put_in(["rules", "content_safety"], safety)
        |> put_in(["guards", "semantic"], semantic)
        |> put_in(["guards", "moderation"], moderation)

      normalized =
        config.source
        |> Map.put("schema_version", 3)
        |> Map.put("guards", guards)
        |> Map.put("rules", rules)

      {:ok, %{source: normalized, settings: settings}}
    else
      {:error, _} = error -> error
      errors -> {:error, errors}
    end
  end

  defp legacy_guards(guards) do
    guards
    |> Map.delete("moderation")
    |> Map.new(fn
      {"semantic", config} when is_map(config) -> {"semantic", Map.delete(config, "severities")}
      entry -> entry
    end)
  end

  defp errors(rules, guards) do
    rule_errors(rules["content_safety"], "content_safety") ++
      rule_errors(rules["prompt_injection"], "prompt_injection") ++
      semantic_errors(guards["semantic"]) ++ moderation_errors(guards["moderation"])
  end

  defp rule_errors(nil, _), do: []

  defp rule_errors(rule, category) when is_map(rule) do
    # Resolved settings contain the fixed zero threshold, authoring does not expose it.
    check(
      Enum.all?(Map.keys(rule), &(&1 in ~w(id action threshold))) &&
        Map.get(rule, "threshold", 0) == 0,
      "rules.#{category}",
      "labels do not have a confidence threshold"
    ) ++
      check(
        !Map.has_key?(rule, "action") || rule["action"] in ~w(allow block),
        "rules.#{category}.action",
        "choose allow or block"
      ) ++
      check(
        !Map.has_key?(rule, "id") || Validation.code?(rule["id"]),
        "rules.#{category}.id",
        "must be a rule identifier"
      )
  end

  defp rule_errors(_, category), do: [{"rules.#{category}", "must be a mapping"}]
  defp semantic_errors(nil), do: []

  defp semantic_errors(config) when is_map(config),
    do: selected(config, "severities", Configuration.severities(), "guards.semantic")

  defp semantic_errors(_), do: [{"guards.semantic", "must be a mapping"}]
  defp moderation_errors(nil), do: []

  defp moderation_errors(config) when is_map(config) do
    path = "guards.moderation"

    check(
      Enum.all?(Map.keys(config), &(&1 in ~w(enabled required stages severities categories))),
      path,
      "contains unknown fields"
    ) ++
      check(
        !Map.has_key?(config, "enabled") || is_boolean(config["enabled"]),
        path,
        "enabled must be true or false"
      ) ++
      check(
        !Map.has_key?(config, "required") || is_boolean(config["required"]),
        path,
        "required must be true or false"
      ) ++
      check(
        !Map.has_key?(config, "stages") || config["stages"] == ["output"],
        path,
        "moderation is output only"
      ) ++
      check(
        config["enabled"] != false || config["required"] == false,
        path,
        "a disabled guard must be optional"
      ) ++
      check(
        config["required"] != true || config["enabled"] == true,
        path,
        "enable moderation before requiring it"
      ) ++
      selected(config, "severities", Configuration.severities(), path) ++
      selected(config, "categories", Configuration.safety_categories(), path)
  end

  defp moderation_errors(_), do: [{"guards.moderation", "must be a mapping"}]

  defp selected(config, key, catalog, path) do
    values = config[key]

    check(
      !Map.has_key?(config, key) ||
        (is_list(values) && values != [] && Enum.all?(values, &(&1 in catalog)) &&
           length(values) == length(Enum.uniq(values))),
      "#{path}.#{key}",
      "choose unique supported values"
    )
  end

  defp check(true, _, _), do: []
  defp check(false, path, message), do: [{path, message}]
end
