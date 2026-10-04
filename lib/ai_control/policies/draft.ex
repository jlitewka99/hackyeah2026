defmodule AiControl.Policies.Draft do
  @moduledoc "Transient form adapter; persisted versions remain immutable."
  use Ecto.Schema

  import Ecto.Changeset

  alias AiControl.Policies.Configuration

  @primary_key false
  embedded_schema do
    field :schema_version, :integer, default: 1
    field :detector_sets, :map, default: %{}
    field :tools, :map, default: %{}
    field :tool_selection, :map
    field :profile, :string
    field :allowed_models, :string
    field :allowed_agents, {:array, :string}, default: []
    field :agent_models, :map, default: %{}
    field :rules, :map, default: %{}
    field :guards, :map, default: %{}
    field :budgets, :map, default: %{}
    field :knowledge, :map, default: %{}
    field :granite, :map, default: %{}
    field :ner_model_set, :string, default: "pl-nkjp.v2"
  end

  @fields ~w(schema_version detector_sets tools tool_selection profile allowed_models allowed_agents agent_models rules guards budgets knowledge granite ner_model_set)a

  def from_source(source) do
    %__MODULE__{
      schema_version: source["schema_version"],
      knowledge: Map.get(source, "knowledge", %{}),
      granite: granite_form(Map.get(source, "granite", %{})),
      ner_model_set: Map.get(source, "ner_model_set", "pl-nkjp.v2"),
      detector_sets: Map.get(source, "detector_sets", %{}),
      tools: Map.get(source, "tools", %{}),
      tool_selection: Map.new(get_in(source, ["tools", "allowed_tools"]) || [], &{&1, "true"}),
      profile: source["profile"],
      allowed_models: Enum.join(source["allowed_models"], "\n"),
      allowed_agents: source["allowed_agents"],
      rules: Map.delete(source["rules"], "granite_violation"),
      budgets: source["budgets"],
      agent_models:
        Map.new(source["agent_models"], fn {id, models} ->
          {id,
           %{
             "mode" => if(models == [], do: "deny", else: "restrict"),
             "models" => Enum.join(models, "\n")
           }}
        end),
      guards:
        Map.new(Map.delete(source["guards"], "granite"), fn {id, guard} ->
          mode =
            cond do
              guard["enabled"] == false -> "disabled"
              guard["required"] == false -> "optional"
              guard["required"] == true -> "required"
              true -> ""
            end

          config = %{"mode" => mode, "stages" => Enum.join(Map.get(guard, "stages", []), ",")}

          config =
            if Map.has_key?(guard, "entities"),
              do: Map.put(config, "entities", guard["entities"]),
              else: config

          config = Map.merge(config, Map.take(guard, ~w(severities categories provider)))
          {id, config}
        end)
    }
    |> change()
  end

  def changeset(attrs), do: cast(%__MODULE__{}, strip_unused(attrs), @fields)

  # LiveView adds these markers at every nesting level to track untouched inputs.
  # They belong to form state, never to the policy authoring format.
  defp strip_unused(attrs) when is_map(attrs) do
    attrs
    |> Enum.reject(fn {key, _} -> is_binary(key) && String.starts_with?(key, "_unused_") end)
    |> Map.new(fn {key, value} -> {key, strip_unused(value)} end)
  end

  defp strip_unused(value), do: value

  def source(changeset) do
    draft = apply_changes(changeset)

    source = %{
      "schema_version" => draft.schema_version,
      "profile" => draft.profile,
      "allowed_models" => lines(draft.allowed_models),
      "allowed_agents" => draft.allowed_agents,
      "rules" => mapping(draft.rules, &rule/1),
      "guards" => mapping(draft.guards, &guard/1),
      "agent_models" => agent_models(draft.agent_models),
      "budgets" => mapping(draft.budgets, &limits/1)
    }

    source =
      if draft.schema_version in [2, 3, 4, 5, 6] do
        Map.merge(source, %{
          "detector_sets" => draft.detector_sets,
          "tools" => selected_tools(draft)
        })
      else
        source
      end

    source =
      if draft.schema_version in [5, 6] do
        knowledge =
          Map.new(draft.knowledge, fn {key, value} ->
            {key,
             if(key in ~w(enabled memory_write_enabled), do: value in [true, "true"], else: value)}
          end)

        Map.merge(source, %{"knowledge" => knowledge, "ner_model_set" => draft.ner_model_set})
      else
        source
      end

    if draft.schema_version == 6,
      do: Map.put(source, "granite", granite_source(draft.granite)),
      else: source
  end

  defp granite_form(%{"criteria" => criteria} = settings) do
    settings
    |> Map.update!("criteria", fn _ ->
      Map.new(criteria, fn {id, c} -> {id, Map.put(c, "id", id)} end)
    end)
    |> Map.update!("privileged_resources", fn resources ->
      Map.new(resources, fn {kind, values} -> {kind, Enum.join(values, "\n")} end)
    end)
  end

  defp granite_form(value), do: value

  defp granite_source(settings) when is_map(settings) do
    if is_map(settings["criteria"]) and is_map(settings["privileged_resources"]) and
         is_list(settings["high_risk_tools"]) and
         Enum.all?(settings["criteria"], fn {_, entry} -> is_map(entry) end) do
      normalize_granite(settings)
    else
      settings
    end
  end

  defp granite_source(value), do: value

  defp normalize_granite(settings) do
    criteria =
      Enum.map(Map.get(settings, "criteria", %{}), fn {key, criterion} ->
        {Map.get(criterion, "id", key),
         criterion |> Map.delete("id") |> Map.update("enabled", false, &(&1 in [true, "true"]))}
      end)

    criteria =
      if length(Enum.uniq_by(criteria, &elem(&1, 0))) == length(criteria),
        do: Map.new(criteria),
        else: criteria

    settings
    |> Map.put("criteria", criteria)
    |> Map.update("enabled", false, &(&1 in [true, "true"]))
    |> Map.update("suspicious_input", false, &(&1 in [true, "true"]))
    |> Map.update("suspicious_threshold", 0.25, fn value -> number(value) end)
    |> Map.update("privileged_resources", %{}, fn resources ->
      Map.new(resources, fn {kind, values} ->
        {kind,
         if(is_binary(values),
           do: values |> String.split("\n", trim: true) |> Enum.map(&String.trim/1),
           else: values
         )}
      end)
    end)
    |> Map.update("high_risk_tools", [], &Enum.reject(&1, fn value -> value == "" end))
  end

  defp selected_tools(%{tool_selection: nil, tools: tools}), do: normalize_tools(tools)

  defp selected_tools(%{tool_selection: selection, tools: tools}) do
    selected = for {tool, value} <- selection, value in [true, "true"], do: tool
    original = Map.get(tools, "allowed_tools", [])

    %{
      "allowed_tools" =>
        Enum.filter(original, &(&1 in selected)) ++ Enum.sort(selected -- original)
    }
  end

  defp normalize_tools(%{"allowed_tools" => values} = tools) when is_list(values),
    do: Map.put(tools, "allowed_tools", Enum.reject(values, &(&1 == "")))

  defp normalize_tools(tools), do: tools

  defp mapping(map, callback) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, callback.(value)} end)

  defp mapping(value, _), do: value

  def validate(attrs) do
    changeset = changeset(attrs)

    case Configuration.validate(source(changeset)) do
      {:ok, config} when changeset.valid? ->
        {:ok, changeset, config}

      {:ok, _} ->
        {:error, %{changeset | action: :validate}, [{"policy", "check the highlighted fields"}]}

      {:error, errors} ->
        changeset = Enum.reduce(errors, changeset, &field_error/2)

        {:error, %{changeset | action: :validate}, errors}
    end
  end

  defp field_error({"profile", message}, changeset), do: add_error(changeset, :profile, message)

  defp field_error({"allowed_models", message}, changeset),
    do: add_error(changeset, :allowed_models, message)

  defp field_error({"allowed_agents", message}, changeset),
    do: add_error(changeset, :allowed_agents, message)

  defp field_error(_, changeset), do: changeset

  defp rule(rule) when is_map(rule) do
    rule
    |> Enum.reject(fn {_, value} -> value in ["", nil] end)
    |> Map.new(fn {key, value} ->
      {key, if(key == "threshold", do: number(value), else: value)}
    end)
  end

  defp rule(value), do: value

  defp limits(limits) when is_map(limits),
    do: Map.new(limits, fn {field, value} -> {field, integer(value)} end)

  defp limits(value), do: value

  defp guard(config) when is_map(config) do
    base = guard_mode(config["mode"])

    base =
      if Map.has_key?(config, "entities"),
        do: Map.put(base, "entities", config["entities"]),
        else: base

    base = Map.merge(base, Map.take(config, ~w(severities categories provider)))

    case config["stages"] do
      value when value in ["", nil] -> base
      value when is_binary(value) -> Map.put(base, "stages", String.split(value, ","))
      _ -> Map.put(base, "stages", :invalid)
    end
  end

  defp guard(value), do: value

  defp guard_mode("disabled"), do: %{"enabled" => false, "required" => false}
  defp guard_mode("optional"), do: %{"enabled" => true, "required" => false}
  defp guard_mode("required"), do: %{"enabled" => true, "required" => true}
  defp guard_mode(value) when value in ["", nil], do: %{}
  defp guard_mode(_), do: %{"enabled" => "invalid"}

  defp agent_models(agents) when is_map(agents) do
    agents
    |> Map.new(fn {id, config} -> {id, agent_models_value(config)} end)
    |> Enum.reject(fn {_, value} -> value == :inherit end)
    |> Map.new()
  end

  defp agent_models(value), do: value

  defp agent_models_value(config) when is_map(config) do
    case config["mode"] do
      value when value in ["inherit", "", nil] -> :inherit
      "deny" -> []
      "restrict" -> lines(config["models"])
      _ -> nil
    end
  end

  defp agent_models_value(_), do: nil

  defp lines(value) when is_binary(value),
    do:
      value
      |> String.split(~r/[\n,]/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp lines(_), do: []

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> value
    end
  end

  defp number(value), do: value
  defp integer(value) when value in [nil, ""], do: nil

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> value
    end
  end

  defp integer(value), do: value
end
