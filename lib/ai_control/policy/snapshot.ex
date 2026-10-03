defmodule AiControl.Policy.Snapshot do
  @moduledoc "Immutable evaluation contract; complete policy settings are covered by its checksum."
  alias AiControl.Policies.Configuration
  alias AiControl.Security.Validation

  defstruct [:version, :checksum, :settings, required_guards: [], rules: %{}]

  @type t :: %__MODULE__{
          version: String.t(),
          checksum: String.t(),
          settings: map() | nil,
          required_guards: [String.t()],
          rules: %{
            String.t() => %{
              optional(:threshold) => number(),
              id: String.t(),
              action: :allow | :redact | :block
            }
          }
        }

  def new(attrs) do
    with {:ok, policy} <-
           Validation.build(
             __MODULE__,
             attrs,
             [:version, :checksum, :settings, :required_guards, :rules],
             &shape?/1
           ),
         checksum = checksum(policy),
         true <- is_nil(policy.checksum) || policy.checksum == checksum do
      {:ok, %{policy | checksum: checksum}}
    else
      _ -> {:error, :invalid_security_data}
    end
  end

  def valid?(%__MODULE__{} = policy),
    do:
      shape?(policy) && Validation.checksum?(policy.checksum) &&
        policy.checksum == checksum(policy)

  def valid?(_), do: false

  def from_version(version) do
    settings = version.settings

    rules =
      Map.new(settings["rules"], fn {category, rule} ->
        action = %{"allow" => :allow, "redact" => :redact, "block" => :block}[rule["action"]]
        {category, %{id: rule["id"], action: action, threshold: rule["threshold"]}}
      end)

    new(%{
      version: "policy-#{version.id}",
      checksum: version.checksum,
      settings: settings,
      rules: rules
    })
  end

  def required_guards(%{settings: nil} = policy, _stage), do: policy.required_guards

  def required_guards(policy, stage) do
    policy.settings["guards"]
    |> Enum.filter(fn {_, guard} ->
      guard["enabled"] && guard["required"] && Atom.to_string(stage) in guard["stages"]
    end)
    |> Enum.map(&elem(&1, 0))
  end

  def enabled?(%{settings: nil}, guard, _stage), do: guard != "ner"

  def enabled?(policy, guard, stage) do
    case policy.settings["guards"][guard] do
      nil -> false
      config -> config["enabled"] && Atom.to_string(stage) in config["stages"]
    end
  end

  defp shape?(policy),
    do:
      Validation.code?(policy.version) && Validation.codes?(policy.required_guards) &&
        length(policy.required_guards) == length(Enum.uniq(policy.required_guards)) &&
        rules?(policy.rules) && settings?(policy)

  defp settings?(%{settings: nil}), do: true

  defp settings?(policy) do
    case Configuration.validate(policy.settings) do
      {:ok, %{settings: settings}} ->
        settings == policy.settings &&
          Enum.all?(policy.rules, fn {category, rule} ->
            configured = settings["rules"][category]

            configured && rule.id == configured["id"] &&
              Atom.to_string(rule.action) == configured["action"] &&
              Map.get(rule, :threshold, 0) == configured["threshold"]
          end) && map_size(policy.rules) == map_size(settings["rules"])

      _ ->
        false
    end
  end

  defp checksum(policy) do
    rules =
      policy.rules
      |> Enum.sort()
      |> Enum.map(fn {category, rule} ->
        {category, rule.id, rule.action, Map.get(rule, :threshold, 0)}
      end)

    data =
      :erlang.term_to_binary(checksum_data(policy, rules))

    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp checksum_data(%{settings: nil} = policy, rules),
    do:
      {"ai_control.policy.snapshot.v1", policy.version, Enum.sort(policy.required_guards), rules}

  defp checksum_data(policy, rules),
    do:
      {"ai_control.policy.snapshot.v2", policy.version, Enum.sort(policy.required_guards), rules,
       canonical(policy.settings)}

  defp canonical(value) when is_map(value),
    do: value |> Enum.sort() |> Enum.map(fn {key, val} -> {key, canonical(val)} end)

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp rules?(rules) when is_map(rules) and not is_struct(rules),
    do: Enum.all?(rules, fn {category, rule} -> Validation.code?(category) && rule?(rule) end)

  defp rules?(_), do: false

  defp rule?(%{id: id, action: action} = rule),
    do:
      Enum.all?(Map.keys(rule), &(&1 in [:id, :action, :threshold])) && Validation.code?(id) &&
        action in [:allow, :redact, :block] && Validation.score?(Map.get(rule, :threshold, 0))

  defp rule?(_), do: false
end
