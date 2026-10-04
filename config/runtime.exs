import Config

# Operator configuration only. A missing catalog permits no model access.
gateway_models =
  case Jason.decode(System.get_env("GATEWAY_MODELS", "{}")) do
    {:ok, models} when is_map(models) -> models
    _ -> raise "GATEWAY_MODELS must be a JSON object of model names and full SHA-256 digests"
  end

gateway_config = [
  semantic_url: System.get_env("SEMANTIC_BASE_URL", "http://127.0.0.1:8003"),
  semantic_timeout: String.to_integer(System.get_env("GATEWAY_SEMANTIC_TIMEOUT_MS", "30000")),
  tokenizer_url: System.get_env("TOKENIZER_BASE_URL", "http://127.0.0.1:8002"),
  tokenizer_timeout: String.to_integer(System.get_env("TOKENIZER_TIMEOUT_MS", "5000")),
  default_max_tokens: String.to_integer(System.get_env("GATEWAY_DEFAULT_MAX_TOKENS", "1024")),
  ip_requests_per_minute:
    String.to_integer(System.get_env("GATEWAY_IP_REQUESTS_PER_MINUTE", "300")),
  prices:
    case Jason.decode(System.get_env("GATEWAY_PRICES", "{}")) do
      {:ok, prices} when is_map(prices) -> prices
      _ -> raise "GATEWAY_PRICES must be a JSON object"
    end,
  ner_url: System.get_env("NER_BASE_URL", "http://127.0.0.1:8001"),
  guard_timeout: String.to_integer(System.get_env("GATEWAY_GUARD_TIMEOUT_MS", "10000")),
  readiness_timeout: String.to_integer(System.get_env("GATEWAY_READINESS_TIMEOUT_MS", "5000")),
  ollama_reasoning_effort:
    case System.get_env("OLLAMA_REASONING_EFFORT", "none") do
      "default" -> nil
      effort when effort in ["none", "low", "medium", "high"] -> effort
      _ -> raise "OLLAMA_REASONING_EFFORT must be default, none, low, medium or high"
    end,
  base_url: System.get_env("OLLAMA_BASE_URL", "http://127.0.0.1:11434"),
  input_bytes: String.to_integer(System.get_env("GATEWAY_INPUT_BYTES", "1048576")),
  response_bytes: String.to_integer(System.get_env("GATEWAY_RESPONSE_BYTES", "4194304")),
  connect_timeout: String.to_integer(System.get_env("GATEWAY_CONNECT_TIMEOUT_MS", "2000")),
  llm_timeout: String.to_integer(System.get_env("GATEWAY_LLM_TIMEOUT_MS", "120000")),
  llm_slots: String.to_integer(System.get_env("GATEWAY_LLM_SLOTS", "1")),
  guard_slots: String.to_integer(System.get_env("GATEWAY_GUARD_SLOTS", "2")),
  requests_per_minute: String.to_integer(System.get_env("GATEWAY_REQUESTS_PER_MINUTE", "60"))
]

gateway_config =
  if config_env() == :test && !System.get_env("GATEWAY_MODELS"),
    do: gateway_config,
    else: Keyword.put(gateway_config, :models, gateway_models)

config :ai_control, AiControl.Gateway.Config, gateway_config

config :ai_control, AiControl.Tools.Config,
  execution_timeout: 10_000,
  sandboxes:
    (case Jason.decode(System.get_env("TOOLS_SANDBOXES", "{}")) do
       {:ok, value} when is_map(value) -> value
       _ -> raise "TOOLS_SANDBOXES must be a JSON object"
     end)

if config_env() == :prod do
  encoded_key =
    System.get_env("AUDIT_FINGERPRINT_KEY") || raise "AUDIT_FINGERPRINT_KEY is required"

  key =
    case Base.decode64(encoded_key) do
      {:ok, value} when byte_size(value) >= 32 -> value
      _ -> raise "AUDIT_FINGERPRINT_KEY must contain at least 32 random bytes encoded as base64"
    end

  key_id = System.get_env("AUDIT_FINGERPRINT_KEY_ID", "v1")

  if !Regex.match?(~r/\A[a-z][a-z0-9_.-]{0,79}\z/, key_id),
    do: raise("AUDIT_FINGERPRINT_KEY_ID must be a machine-readable identifier")

  config :ai_control, AiControl.Security.Fingerprint, key: key, key_id: key_id
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/ai_control start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :ai_control, AiControlWeb.Endpoint, server: true
end

config :ai_control, AiControlWeb.Endpoint,
  http: [
    port: String.to_integer(System.get_env("PORT", "4000")),
    http_options: Application.fetch_env!(:ai_control, :http_log_options)
  ]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :ai_control, AiControlWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/ai_control_web/router\.ex$"E,
        ~r"lib/ai_control_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :ai_control, AiControl.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :ai_control, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :ai_control, AiControlWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :ai_control, AiControlWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :ai_control, AiControlWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :ai_control, AiControl.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
