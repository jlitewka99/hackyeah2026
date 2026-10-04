defmodule AiControl.Policies.Configuration do
  @moduledoc "Versioned policy dispatch; legacy defaults and checksums remain frozen."
  alias AiControl.Policies.{ConfigurationV2, ConfigurationV3, ConfigurationV4, ConfigurationV5}

  def profiles, do: ConfigurationV2.profiles()

  def categories(version \\ 1),
    do: ConfigurationV2.categories() ++ if(version in [3, 4, 5], do: ["content_safety"], else: [])

  def guards(version \\ 1),
    do:
      ConfigurationV2.guards(min(version, 2)) ++
        if(version in [3, 4, 5], do: ["moderation"], else: [])

  def ner_entities, do: ConfigurationV2.ner_entities()

  def budget_fields(version \\ 1) do
    fields = ConfigurationV2.budget_fields()
    if version == 5, do: Map.put(fields, "workflow", ConfigurationV5.fields()), else: fields
  end

  def severities, do: ~w(Unsafe Controversial)

  def safety_categories,
    do: [
      "Violent",
      "Non-violent Illegal Acts",
      "Sexual Content or Sexual Acts",
      "PII",
      "Suicide & Self-Harm",
      "Unethical Acts",
      "Politically Sensitive Topics",
      "Copyright Violation"
    ]

  def default(version \\ 1)

  def default(5),
    do:
      default(4)
      |> Map.put("schema_version", 5)
      |> put_in(["budgets", "workflow"], ConfigurationV5.defaults())

  def default(4), do: default(3) |> Map.put("schema_version", 4)
  def default(3), do: ConfigurationV2.default(2) |> Map.put("schema_version", 3)
  def default(version), do: ConfigurationV2.default(version)
  def upgrade(source, version \\ 3)

  def upgrade(source, 5) do
    source = upgrade(source, 4) |> Map.put("schema_version", 5)
    prior = get_in(source, ["budgets", "workflow"]) || %{}
    limits = Map.merge(ConfigurationV5.defaults(), Map.reject(prior, fn {_, v} -> is_nil(v) end))
    budgets = Map.get(source, "budgets", %{})
    Map.put(source, "budgets", Map.put(budgets, "workflow", limits))
  end

  def upgrade(source, 4), do: upgrade(source, 3) |> Map.put("schema_version", 4)
  def upgrade(source, 2), do: ConfigurationV2.upgrade(source)

  def upgrade(source, 3) do
    source = ConfigurationV2.upgrade(source) |> Map.put("schema_version", 3)

    update_in(source, ["rules"], fn rules ->
      case rules["prompt_injection"] do
        nil -> rules
        rule -> Map.put(rules, "prompt_injection", Map.delete(rule, "threshold"))
      end
    end)
  end

  def validate(%{"schema_version" => 5} = source), do: ConfigurationV5.validate(source)
  def validate(%{"schema_version" => 4} = source), do: ConfigurationV4.validate(source)
  def validate(%{"schema_version" => 3} = source), do: ConfigurationV3.validate(source)
  def validate(source), do: ConfigurationV2.validate(source)
end
