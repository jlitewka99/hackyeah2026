defmodule AiControl.Policies.ConfigurationV4 do
  @moduledoc "Snapshot-owned injection provider and score threshold; moderation remains Qwen."
  alias AiControl.Policies.ConfigurationV3
  alias AiControl.Security.Validation

  def validate(source) do
    with guards when is_map(guards) <- Map.get(source, "guards", %{}),
         rules when is_map(rules) <- Map.get(source, "rules", %{}),
         semantic when is_map(semantic) <- Map.get(guards, "semantic", %{}),
         injection when is_map(injection) <- Map.get(rules, "prompt_injection", %{}),
         provider = Map.get(semantic, "provider", "qwen"),
         :ok <- validate_provider(provider),
         threshold = Map.get(injection, "threshold", default_threshold(source, provider)),
         :ok <- validate_threshold(threshold, provider),
         base =
           source
           |> Map.put("schema_version", 3)
           |> put_in(["guards"], Map.put(guards, "semantic", Map.delete(semantic, "provider")))
           |> put_in(
             ["rules"],
             Map.put(rules, "prompt_injection", Map.put(injection, "threshold", 0))
           ),
         {:ok, config} <- ConfigurationV3.validate(base) do
      settings =
        config.settings
        |> Map.put("schema_version", 4)
        |> put_in(["guards", "semantic", "provider"], provider)
        |> put_in(["rules", "prompt_injection", "threshold"], threshold)

      {:ok,
       %{
         source:
           config.source
           |> Map.put("schema_version", 4)
           |> Map.put("guards", guards)
           |> Map.put("rules", rules),
         settings: settings
       }}
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         [
           {"guards.semantic.provider",
            "choose qwen or prompt_guard with a valid score threshold; Qwen uses zero"}
         ]}
    end
  end

  defp validate_provider(provider) do
    if provider in ~w(qwen prompt_guard),
      do: :ok,
      else: {:error, [{"guards.semantic.provider", "choose qwen or prompt_guard"}]}
  end

  defp validate_threshold(threshold, provider) do
    if Validation.score?(threshold) && (provider != "qwen" || threshold == 0),
      do: :ok,
      else:
        {:error,
         [{"rules.prompt_injection.threshold", "use a score from 0 to 1; Qwen uses zero"}]}
  end

  defp default_threshold(_source, "qwen"), do: 0

  defp default_threshold(source, _),
    do: %{"relaxed" => 0.9, "balanced" => 0.8, "strict" => 0.65}[source["profile"] || "balanced"]
end
