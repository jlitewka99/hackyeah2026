defmodule AiControl.Policies.ConfigurationV1 do
  @moduledoc "Frozen schema v1 validation and normalization. Keep historical policy checksums stable."
  alias AiControl.Security.Validation

  @categories ~w(pii secret exploit prompt_injection)
  @guards ~w(pii secret signatures semantic)
  @keys ~w(schema_version profile rules guards allowed_models allowed_agents agent_models budgets)
  @budget_fields %{
    "organization" => ~w(requests_per_hour tokens_per_hour),
    "agent" => ~w(requests_per_hour tokens_per_hour),
    "workflow" => ~w(tool_calls)
  }

  def categories, do: @categories
  def guards, do: @guards
  def budget_fields, do: @budget_fields
  def profiles, do: ~w(relaxed balanced strict)

  def default do
    %{
      "schema_version" => 1,
      "profile" => "balanced",
      "allowed_models" => ["qwen3.5:4b"],
      "allowed_agents" => ["*"],
      "agent_models" => %{},
      "rules" => %{},
      "guards" => %{},
      "budgets" => %{}
    }
  end

  def validate(source) when is_map(source) and not is_struct(source) do
    errors =
      unknown(source, @keys, "policy") ++
        check(source["schema_version"] == 1, "schema_version", "must be 1") ++
        check(source["profile"] in profiles(), "profile", "choose a supported profile") ++
        selectors(source["allowed_models"], "allowed_models", &model?/1) ++
        selectors(source["allowed_agents"], "allowed_agents", &Validation.uuid?/1) ++
        rule_errors(Map.get(source, "rules", %{})) ++
        guard_errors(Map.get(source, "guards", %{})) ++
        agent_errors(Map.get(source, "agent_models", %{})) ++
        budget_errors(Map.get(source, "budgets", %{}))

    if errors == [] do
      normalized = Map.merge(default(), source)
      {:ok, %{source: normalized, settings: resolve(normalized)}}
    else
      {:error, errors}
    end
  end

  def validate(_), do: {:error, [{"policy", "must be a mapping"}]}

  defp resolve(source) do
    profile = source["profile"]
    threshold = %{"relaxed" => 0.9, "balanced" => 0.8, "strict" => 0.65}[profile]

    rules =
      Map.new(@categories, fn category ->
        defaults = %{
          "id" => "#{category}.default",
          "action" => if(category == "pii" && profile != "strict", do: "redact", else: "block"),
          "threshold" => if(category == "prompt_injection", do: threshold, else: 0)
        }

        {category, Map.merge(defaults, Map.get(source["rules"], category, %{}))}
      end)

    guards =
      Map.new(@guards, fn guard ->
        defaults = %{
          "enabled" => true,
          "required" => guard != "semantic" || profile != "relaxed",
          "stages" => if(guard == "semantic", do: ["input"], else: ["input", "output"])
        }

        {guard, Map.merge(defaults, Map.get(source["guards"], guard, %{}))}
      end)

    budgets =
      Map.new(@budget_fields, fn {scope, fields} ->
        {scope, Map.merge(Map.new(fields, &{&1, nil}), Map.get(source["budgets"], scope, %{}))}
      end)

    source |> Map.put("rules", rules) |> Map.put("guards", guards) |> Map.put("budgets", budgets)
  end

  defp rule_errors(rules) do
    mappings(rules, @categories, "rules", fn category, rule ->
      path = "rules.#{category}"

      unknown(rule, ~w(id action threshold), path) ++
        optional(rule, "id", path, &Validation.code?/1, "must be a rule identifier") ++
        optional(
          rule,
          "action",
          path,
          &(&1 in ~w(allow redact block)),
          "choose allow, redact or block"
        ) ++
        optional(rule, "threshold", path, &Validation.score?/1, "must be between 0 and 1")
    end)
  end

  defp guard_errors(guards) do
    mappings(guards, @guards, "guards", fn guard, rule ->
      path = "guards.#{guard}"

      unknown(rule, ~w(enabled required stages), path) ++
        optional(rule, "enabled", path, &is_boolean/1, "must be true or false") ++
        optional(rule, "required", path, &is_boolean/1, "must be true or false") ++
        optional(rule, "stages", path, &stages?/1, "choose input and/or output") ++
        check(
          rule["enabled"] != false || rule["required"] == false,
          path,
          "a disabled guard must be optional"
        )
    end)
  end

  defp agent_errors(agents) when is_map(agents) and not is_struct(agents) do
    check(map_size(agents) <= 500, "agent_models", "at most 500 agents") ++
      Enum.flat_map(agents, fn {agent, models} ->
        check(Validation.uuid?(agent), "agent_models", "keys must be agent UUIDs") ++
          selectors(models, "agent_models", &model?/1)
      end)
  end

  defp agent_errors(_), do: [{"agent_models", "must be a mapping"}]

  defp budget_errors(budgets) do
    mappings(budgets, Map.keys(@budget_fields), "budgets", fn scope, limits ->
      path = "budgets.#{scope}"

      unknown(limits, @budget_fields[scope], path) ++
        Enum.flat_map(limits, fn {field, value} ->
          check(
            is_nil(value) || (is_integer(value) && value >= 0),
            "#{path}.#{field}",
            "must be a nonnegative integer or null"
          )
        end)
    end)
  end

  defp mappings(value, allowed, path, callback) when is_map(value) and not is_struct(value) do
    unknown(value, allowed, path) ++
      Enum.flat_map(value, fn {key, entry} ->
        cond do
          key not in allowed -> []
          is_map(entry) && !is_struct(entry) -> callback.(key, entry)
          true -> [{"#{path}.#{key}", "must be a mapping"}]
        end
      end)
  end

  defp mappings(_, _, path, _), do: [{path, "must be a mapping"}]

  defp unknown(map, keys, path) do
    if Enum.all?(Map.keys(map), &(&1 in keys)), do: [], else: [{path, "contains unknown fields"}]
  end

  defp optional(map, field, path, validate, message) do
    if Map.has_key?(map, field),
      do: check(validate.(map[field]), "#{path}.#{field}", message),
      else: []
  end

  defp selectors(values, path, validate) when is_list(values) do
    valid? =
      length(values) <= 500 && length(Enum.uniq(values)) == length(values) &&
        (values == ["*"] || Enum.all?(values, &(is_binary(&1) && &1 != "*" && validate.(&1))))

    check(valid?, path, "use unique resource names or a single wildcard")
  end

  defp selectors(_, path, _), do: [{path, "must be a list"}]

  defp model?(value),
    do: byte_size(value) in 1..200 && Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.:\/-]*\z/, value)

  defp stages?(values),
    do:
      is_list(values) && values != [] && Enum.all?(values, &(&1 in ~w(input output))) &&
        length(Enum.uniq(values)) == length(values)

  defp check(true, _, _), do: []
  defp check(false, path, message), do: [{path, message}]
end
