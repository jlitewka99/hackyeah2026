defmodule AiControl.Gateway.Config do
  @moduledoc "Operator-owned gateway configuration; never populated from API parameters."
  alias AiControl.Budgets.Pricing
  alias AiControl.Policies.Configuration

  @defaults [
    base_url: "http://127.0.0.1:11434",
    provider: AiControl.Gateway.Ollama,
    ollama_reasoning_effort: "none",
    models: %{},
    guards: %{
      "pii" => AiControl.Guards.Pii,
      "secret" => AiControl.Guards.Secret,
      "signatures" => AiControl.Guards.Signatures,
      "ner" => AiControl.Guards.Ner,
      "semantic" => AiControl.Guards.Semantic,
      "moderation" => AiControl.Guards.Moderation
    },
    ner_url: "http://127.0.0.1:8001",
    semantic_url: "http://127.0.0.1:8003",
    prompt_guard_url: "http://127.0.0.1:8004",
    semantic_timeout: 30_000,
    input_bytes: 1_048_576,
    response_bytes: 4_194_304,
    connect_timeout: 2_000,
    llm_timeout: 120_000,
    guard_timeout: 10_000,
    readiness_timeout: 5_000,
    llm_slots: 1,
    guard_slots: 2,
    tool_slots: 1,
    requests_per_minute: 60,
    ip_requests_per_minute: 300,
    default_max_tokens: 1024,
    tokenizer_url: "http://127.0.0.1:8002",
    tokenizer_timeout: 5_000,
    tokenizer: AiControl.Budgets.Tokenizer,
    prices: %{}
  ]

  def get, do: Keyword.merge(@defaults, Application.get_env(:ai_control, __MODULE__, []))
  def guard_modules, do: Keyword.fetch!(@defaults, :guards)
  def get(key), do: Keyword.fetch!(get(), key)

  def validate! do
    config = get()

    if !origin?(config[:base_url]),
      do: raise(ArgumentError, "gateway base_url must be an HTTP origin")

    if !catalog?(config[:models]),
      do: raise(ArgumentError, "gateway models require names and full SHA-256 digests")

    if !origin?(config[:ner_url]), do: raise(ArgumentError, "ner_url must be an HTTP origin")

    validate_semantic!(config)
    validate_limits!(config)

    if !origin?(config[:tokenizer_url]),
      do: raise(ArgumentError, "tokenizer_url must be an HTTP origin")

    if !Pricing.valid?(config[:prices]),
      do: raise(ArgumentError, "invalid token pricing")

    if config[:default_max_tokens] > 32_768,
      do: raise(ArgumentError, "default_max_tokens exceeds supported maximum")

    if !guards?(config[:guards]),
      do: raise(ArgumentError, "gateway guards must use the policy guard catalog")

    if config[:ollama_reasoning_effort] not in [nil, "none", "low", "medium", "high"],
      do: raise(ArgumentError, "unsupported Ollama reasoning effort")

    :ok
  end

  defp validate_semantic!(config) do
    if !origin?(config[:prompt_guard_url]),
      do: raise(ArgumentError, "prompt_guard_url must be an HTTP origin")

    if !origin?(config[:semantic_url]),
      do: raise(ArgumentError, "semantic_url must be an HTTP origin")

    if !(is_integer(config[:semantic_timeout]) && config[:semantic_timeout] in 1..30_000),
      do: raise(ArgumentError, "semantic_timeout must be between 1 and 30000 ms")
  end

  defp origin?(url) when is_binary(url) do
    uri = URI.parse(url)

    uri.scheme in ["http", "https"] && is_binary(uri.host) && uri.host != "" &&
      is_nil(uri.userinfo) && uri.path in [nil, "", "/"] && is_nil(uri.query) &&
      is_nil(uri.fragment)
  end

  defp origin?(_), do: false

  defp catalog?(models),
    do: is_map(models) && map_size(models) <= 500 && Enum.all?(models, &model?/1)

  defp model?({name, digest}),
    do:
      is_binary(name) && Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.:\/-]{0,199}\z/, name) &&
        is_binary(digest) && Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp guards?(guards),
    do:
      is_map(guards) &&
        Enum.all?(guards, fn {name, module} ->
          name in Configuration.guards(3) && is_atom(module)
        end)

  defp validate_limits!(config) do
    for key <-
          ~w(input_bytes response_bytes connect_timeout llm_timeout guard_timeout readiness_timeout llm_slots guard_slots tool_slots requests_per_minute ip_requests_per_minute default_max_tokens tokenizer_timeout)a do
      if !(is_integer(config[key]) && config[key] > 0),
        do: raise(ArgumentError, "gateway limits must be positive integers")
    end
  end
end
