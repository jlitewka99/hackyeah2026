defmodule AiControl.Gateway.Readiness do
  @moduledoc "Bounded readiness of effective policies, pinned models and required guard adapters."
  alias AiControl.{Gateway, Policies, Repo}
  alias AiControl.Gateway.{Config, Slots}
  alias AiControl.Guards.Semantic
  alias AiControl.Policy.Snapshot
  alias Ecto.Adapters.SQL

  def check, do: Slots.run(:guard, Config.get(:readiness_timeout), &dependencies/0)

  defp dependencies do
    config = Config.get() |> Keyword.put(:llm_timeout, Config.get(:readiness_timeout))
    provider = config[:provider]

    with {:ok, _} <- SQL.query(Repo, "SELECT 1", [], log: false),
         {:ok, policies} when policies != [] <- Policies.readiness_snapshots(),
         true <- map_size(config[:models]) > 0,
         {:ok, models} <- provider.models(config),
         true <- pinned_catalog?(config, models),
         true <- guards_ready?(policies, config),
         true <- tokenizer_ready?(policies, config) do
      :ok
    else
      _ -> {:error, :not_ready}
    end
  end

  defp tokenizer_ready?(policies, config) do
    if Enum.any?(policies, &AiControl.Budgets.hard_limit?/1) do
      tokenizer = config[:tokenizer]
      tokenizer.ready?(config)
    else
      true
    end
  end

  defp pinned_catalog?(config, models),
    do:
      Enum.all?(config[:models], fn {name, digest} ->
        Gateway.pinned(models, name, digest) == :ok
      end)

  defp guards_ready?(policies, config) do
    policies
    |> Enum.flat_map(fn policy ->
      guards =
        Snapshot.required_guards(policy, :input) ++ Snapshot.required_guards(policy, :output)

      Enum.map(
        guards,
        &{&1,
         if(&1 == "semantic",
           do: Semantic.selected_provider(policy),
           else: "qwen"
         )}
      )
    end)
    |> Enum.uniq()
    |> Enum.all?(fn {guard, provider} ->
      case config[:guards][guard] do
        nil -> false
        module -> module.ready?(Keyword.put(config, :injection_provider, provider)) == true
      end
    end)
  end
end
