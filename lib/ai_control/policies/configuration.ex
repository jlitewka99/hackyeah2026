defmodule AiControl.Policies.Configuration do
  @moduledoc "Versioned policy dispatch; legacy defaults and checksums remain frozen."
  alias AiControl.Policies.{
    ConfigurationV2,
    ConfigurationV3,
    ConfigurationV4,
    ConfigurationV5,
    ConfigurationV6
  }

  def profiles, do: ConfigurationV2.profiles()

  def categories(version \\ 1),
    do:
      ConfigurationV2.categories() ++
        if(version in [3, 4, 5, 6], do: ["content_safety"], else: []) ++
        if(version == 6, do: ["granite_violation"], else: [])

  def guards(version \\ 1),
    do:
      ConfigurationV2.guards(min(version, 2)) ++
        if(version in [3, 4, 5, 6], do: ["moderation"], else: []) ++
        if(version == 6, do: ["granite"], else: [])

  def ner_entities, do: ConfigurationV2.ner_entities()

  def budget_fields(version \\ 1) do
    fields = ConfigurationV2.budget_fields()
    if version in [5, 6], do: Map.put(fields, "workflow", ConfigurationV5.fields()), else: fields
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
  def default(6), do: upgrade(default(5), 6)
  def default(5), do: upgrade(default(4), 5)
  def default(4), do: default(3) |> Map.put("schema_version", 4)
  def default(3), do: ConfigurationV2.default(2) |> Map.put("schema_version", 3)
  def default(version), do: ConfigurationV2.default(version)
  def upgrade(source, version \\ 3)

  def upgrade(source, 6) do
    source = if source["schema_version"] in [5, 6], do: source, else: upgrade(source, 5)
    source |> Map.put("schema_version", 6) |> Map.put_new("granite", ConfigurationV6.defaults())
  end

  def upgrade(source, 5) do
    version = if source["schema_version"] == 6, do: 6, else: 5

    source =
      if(source["schema_version"] in [4, 5, 6], do: source, else: upgrade(source, 4))
      |> Map.put("schema_version", version)

    prior = get_in(source, ["budgets", "workflow"]) || %{}

    limits =
      Map.merge(
        ConfigurationV5.workflow_defaults(),
        Map.reject(prior, fn {_, v} -> is_nil(v) end)
      )

    budgets = Map.get(source, "budgets", %{})

    source
    |> Map.put("budgets", Map.put(budgets, "workflow", limits))
    |> Map.put_new("knowledge", ConfigurationV5.defaults())
    |> Map.put_new("ner_model_set", "pl-nkjp.v2")
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

  def validate(%{"schema_version" => 6} = source), do: ConfigurationV6.validate(source)
  def validate(%{"schema_version" => 5} = source), do: ConfigurationV5.validate(source)

  def validate(%{"schema_version" => 4} = source), do: ConfigurationV4.validate(source)
  def validate(%{"schema_version" => 3} = source), do: ConfigurationV3.validate(source)
  def validate(source), do: ConfigurationV2.validate(source)

  def workflow?(%{"schema_version" => version}), do: version in [5, 6]
  def workflow?(_), do: false
end
