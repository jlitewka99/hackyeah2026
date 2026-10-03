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
    field :profile, :string
    field :allowed_models, :string
    field :allowed_agents, {:array, :string}, default: []
    field :agent_models, :map, default: %{}
    field :rules, :map, default: %{}
    field :guards, :map, default: %{}
    field :budgets, :map, default: %{}
  end

  @fields ~w(schema_version detector_sets tools profile allowed_models allowed_agents agent_models rules guards budgets)a

  def from_source(source) do
    %__MODULE__{
      schema_version: source["schema_version"],
      detector_sets: Map.get(source, "detector_sets", %{}),
      tools: Map.get(source, "tools", %{}),
      profile: source["profile"],
      allowed_models: Enum.join(source["allowed_models"], "\n"),
      allowed_agents: source["allowed_agents"],
      rules: source["rules"],
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
        Map.new(source["guards"], fn {id, guard} ->
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

          config = Map.merge(config, Map.take(guard, ~w(severities categories)))
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

    if draft.schema_version in [2, 3] do
      Map.merge(source, %{
        "detector_sets" => draft.detector_sets,
        "tools" => normalize_tools(draft.tools)
      })
    else
      source
    end
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

    base = Map.merge(base, Map.take(config, ~w(severities categories)))

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
