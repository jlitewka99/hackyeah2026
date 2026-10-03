defmodule AiControl.Policy.Snapshot do
  @moduledoc "The minimal immutable evaluation contract. Storage and activation arrive in step 5."
  alias AiControl.Security.Validation

  defstruct [:version, :checksum, required_guards: [], rules: %{}]

  @type t :: %__MODULE__{
          version: String.t(),
          checksum: String.t(),
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
             [:version, :checksum, :required_guards, :rules],
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

  defp shape?(policy),
    do:
      Validation.code?(policy.version) && Validation.codes?(policy.required_guards) &&
        length(policy.required_guards) == length(Enum.uniq(policy.required_guards)) &&
        rules?(policy.rules)

  defp checksum(policy) do
    rules =
      policy.rules
      |> Enum.sort()
      |> Enum.map(fn {category, rule} ->
        {category, rule.id, rule.action, Map.get(rule, :threshold, 0)}
      end)

    data =
      :erlang.term_to_binary(
        {"ai_control.policy.snapshot.v1", policy.version, Enum.sort(policy.required_guards),
         rules}
      )

    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp rules?(rules) when is_map(rules) and not is_struct(rules),
    do: Enum.all?(rules, fn {category, rule} -> Validation.code?(category) && rule?(rule) end)

  defp rules?(_), do: false

  defp rule?(%{id: id, action: action} = rule),
    do:
      Enum.all?(Map.keys(rule), &(&1 in [:id, :action, :threshold])) && Validation.code?(id) &&
        action in [:allow, :redact, :block] && Validation.score?(Map.get(rule, :threshold, 0))

  defp rule?(_), do: false
end
