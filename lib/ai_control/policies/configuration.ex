defmodule AiControl.Policies.Configuration do
  @moduledoc "Versioned policy dispatch; legacy defaults and checksums remain frozen."
  alias AiControl.Policies.{ConfigurationV2, ConfigurationV3}

  def profiles, do: ConfigurationV2.profiles()

  def categories(version \\ 1),
    do: ConfigurationV2.categories() ++ if(version == 3, do: ["content_safety"], else: [])

  def guards(version \\ 1),
    do: ConfigurationV2.guards(min(version, 2)) ++ if(version == 3, do: ["moderation"], else: [])

  def ner_entities, do: ConfigurationV2.ner_entities()
  def budget_fields, do: ConfigurationV2.budget_fields()
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
  def default(3), do: ConfigurationV2.default(2) |> Map.put("schema_version", 3)
  def default(version), do: ConfigurationV2.default(version)
  def upgrade(source, version \\ 3)
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

  def validate(%{"schema_version" => 3} = source), do: ConfigurationV3.validate(source)
  def validate(source), do: ConfigurationV2.validate(source)
end
