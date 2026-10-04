defmodule AiControl.Policies.ConfigurationV6 do
  @moduledoc "Opt-in Granite and human review; existing v6 snapshots retain their shape."
  alias AiControl.Guards.Granite.Criteria
  alias AiControl.Policies.ConfigurationV5
  alias AiControl.Security.Validation
  alias AiControl.Tools.{Catalog, Resources}

  @resources ~w(paths tables endpoints recipients commands)
  def defaults do
    %{
      "enabled" => false,
      "suspicious_input" => true,
      "suspicious_threshold" => 0.25,
      "high_risk_tools" => ~w(file.write file.delete http.get email.send command.run),
      "privileged_resources" => Map.new(@resources, &{&1, []}),
      "criteria" => Criteria.defaults()
    }
  end

  def resource_kinds, do: @resources

  def review_defaults,
    do: %{"enabled" => false, "tools" => [], "llm_models" => [], "delegation_agents" => []}

  def validate(source) do
    granite = Map.get(source, "granite", %{})

    with true <- is_map(granite) and not is_struct(granite),
         settings = Map.merge(defaults(), granite),
         :ok <- validate_granite(settings),
         :ok <- derived_fields(source, settings),
         {:ok, review} <- review_settings(source),
         base = legacy(source),
         {:ok, config} <- ConfigurationV5.validate(base) do
      config = %{
        source: Map.put(config.source, "schema_version", 6),
        settings: Map.put(config.settings, "schema_version", 6)
      }

      config =
        if Map.has_key?(source, "granite") do
          %{
            source: Map.put(config.source, "granite", settings),
            settings:
              config.settings
              |> Map.put("granite", settings)
              |> put_in(["guards", "granite"], guard(settings))
              |> put_in(["rules", "granite_violation"], rule())
          }
        else
          config
        end

      config =
        if Map.has_key?(source, "review"),
          do: %{
            source: Map.put(config.source, "review", review),
            settings: Map.put(config.settings, "review", review)
          },
          else: config

      {:ok, config}
    else
      {:error, _} = error -> error
      _ -> {:error, [{"granite", "use valid deep analysis settings"}]}
    end
  end

  defp legacy(source) do
    source
    |> Map.drop(["granite", "review"])
    |> Map.put("schema_version", 5)
    |> Map.update("guards", %{}, fn
      value when is_map(value) -> Map.delete(value, "granite")
      value -> value
    end)
    |> Map.update("rules", %{}, fn
      value when is_map(value) -> Map.delete(value, "granite_violation")
      value -> value
    end)
  end

  defp review_settings(source) do
    review = Map.get(source, "review", %{})

    with true <- is_map(review) and not is_struct(review),
         true <- Enum.all?(Map.keys(review), &(&1 in Map.keys(review_defaults()))),
         settings = Map.merge(review_defaults(), review),
         true <- is_boolean(settings["enabled"]),
         true <- review_tools?(settings["tools"]),
         true <- review_names?(settings["llm_models"]),
         true <- review_agents?(settings["delegation_agents"]) do
      {:ok, settings}
    else
      _ ->
        {:error,
         [{"review", "choose an explicit switch and valid tool, model and agent selectors"}]}
    end
  end

  defp review_tools?(items),
    do:
      is_list(items) and Enum.uniq(items) == items and
        Enum.all?(items, &(&1 in Enum.map(Catalog.all(), fn tool -> tool["name"] end)))

  defp review_names?(items),
    do:
      is_list(items) and length(items) <= 500 and Enum.uniq(items) == items and
        ("*" not in items or items == ["*"]) and
        Enum.all?(items, &(is_binary(&1) and byte_size(&1) in 1..200))

  defp review_agents?(items),
    do:
      review_names?(items) and
        (items == ["*"] or Enum.all?(items, &match?({:ok, _}, Ecto.UUID.cast(&1))))

  defp guard(settings),
    do: %{"enabled" => settings["enabled"], "required" => false, "stages" => ~w(input output)}

  defp rule, do: %{"id" => "granite.violation.v1", "action" => "block", "threshold" => 0}

  defp derived_fields(source, settings) do
    guards = Map.get(source, "guards", %{})
    rules = Map.get(source, "rules", %{})

    if is_map(guards) and is_map(rules) and
         (Map.has_key?(source, "granite") or
            (not Map.has_key?(guards, "granite") and
               not Map.has_key?(rules, "granite_violation"))) and
         Map.get(guards, "granite", guard(settings)) == guard(settings) and
         Map.get(rules, "granite_violation", rule()) == rule(),
       do: :ok,
       else: {:error, [{"granite", "selected checks are mandatory and violations always block"}]}
  end

  defp validate_granite(settings) do
    tools = Enum.map(Catalog.all(), & &1["name"])

    cond do
      Enum.any?(Map.keys(settings), &(&1 not in Map.keys(defaults()))) ->
        error("granite", "contains unknown fields")

      !switches?(settings) ->
        error("granite", "switches must be true or false")

      !Validation.score?(settings["suspicious_threshold"]) ->
        error("granite.suspicious_threshold", "use a score from 0 to 1")

      !selected?(settings["high_risk_tools"], &(&1 in tools)) ->
        error("granite.high_risk_tools", "choose unique catalog operations")

      !resources?(settings["privileged_resources"]) ->
        error("granite.privileged_resources", "use exact resource selectors without wildcards")

      !criteria?(settings["criteria"]) ->
        error(
          "granite.criteria",
          "use 1–8 unique criterion IDs, a task, text and yes/no polarity"
        )

      !covered?(settings) ->
        error("granite.criteria", "enable at least one criterion for every selected task")

      true ->
        :ok
    end
  end

  defp switches?(settings),
    do: is_boolean(settings["enabled"]) and is_boolean(settings["suspicious_input"])

  defp resources?(value) when is_map(value) and not is_struct(value),
    do:
      Map.keys(value) |> Enum.sort() == Enum.sort(@resources) and
        Enum.all?(value, fn {kind, items} -> selected?(items, &resource?(kind, &1)) end)

  defp resources?(_), do: false

  defp resource?("paths", value),
    do: Resources.canonical_path?(value) and not String.contains?(value, "*")

  defp resource?("tables", value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, value)

  defp resource?(_, value),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..1024 and
        !String.contains?(value, ["*", "\n", "\r", "\0"])

  defp selected?(values, validator) when is_list(values),
    do: length(values) <= 64 and Enum.uniq(values) == values and Enum.all?(values, validator)

  defp selected?(_, _), do: false

  defp criteria?(criteria) when is_map(criteria) and not is_struct(criteria),
    do:
      map_size(criteria) in 1..8 and
        Enum.all?(criteria, fn {id, entry} -> Validation.code?(id) and criterion?(entry) end)

  defp criteria?(_), do: false

  defp criterion?(entry) when is_map(entry) and not is_struct(entry),
    do:
      Map.keys(entry) |> Enum.sort() == Enum.sort(~w(task text block_on enabled)) and
        entry["task"] in Criteria.tasks() and entry["block_on"] in ~w(yes no) and
        is_boolean(entry["enabled"]) and is_binary(entry["text"]) and String.valid?(entry["text"]) and
        byte_size(String.trim(entry["text"])) in 1..4096

  defp criterion?(_), do: false

  defp covered?(%{"enabled" => false}), do: true

  defp covered?(settings) do
    tasks =
      ["groundedness"] ++
        if(settings["suspicious_input"], do: ["suspicious_input"], else: []) ++
        if(
          settings["high_risk_tools"] != [] or
            Enum.any?(settings["privileged_resources"], fn {_, v} -> v != [] end),
          do: ["tool_action"],
          else: []
        )

    Enum.all?(tasks, fn task ->
      Enum.any?(settings["criteria"], fn {_, c} -> c["enabled"] and c["task"] == task end)
    end)
  end

  defp error(path, message), do: {:error, [{path, message}]}
end
