defmodule AiControl.Guards.Secret do
  @moduledoc "Offline credential signatures and contextual heuristics; no credential verification."
  @behaviour AiControl.Gateway.Guard

  alias AiControl.Guards.{Finding, Registry}

  @impl true
  def assess(fields, _context, _snapshot, _config),
    do: Finding.scan(fields, "secret", "secret", detectors())

  @impl true
  def ready?(_), do: Registry.valid?()

  defp detectors do
    always = fn _, _, _ -> true end

    [
      {"secret.pem.v1",
       ~r/-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----[\s\S]*?(?:-----END (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|\z)/,
       always},
      {"secret.aws.v1", ~r/(?<![A-Za-z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9])/, always},
      {"secret.github.v1",
       ~r/(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,255})(?![A-Za-z0-9_])/,
       always},
      {"secret.google.v1",
       ~r/(?<![A-Za-z0-9_])(?:AIza[A-Za-z0-9_-]{35}|ya29\.[A-Za-z0-9_-]{20,255})(?![A-Za-z0-9_-])/,
       always},
      {"secret.jwt.v1",
       ~r/(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{2,2048}\.[A-Za-z0-9_-]{2,8192}\.[A-Za-z0-9_-]{0,2048}(?![A-Za-z0-9_.-])/,
       fn value, _, _ -> jwt?(value) end},
      {"secret.bearer.v1", ~r/\bBearer[ \t]+([A-Za-z0-9._~+\/-]{8,4096}=*)/i, always},
      {"secret.password.v1",
       ~r/\b(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?token|aws_secret_access_key)\b["']?[ \t]*[:=][ \t]*["']?([^\s"',;}{]{1,4096})/i,
       fn value, _, _ -> literal?(value) end},
      {"secret.connection.v1",
       ~r/\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqps?):\/\/[^\s:@\/]{1,200}:([^\s@\/]{1,4096})@/i,
       fn value, _, _ -> literal?(value) end},
      {"secret.entropy.v1",
       ~r/\b(?:token|credential|authorization)\b["']?[ \t]*[:=][ \t]*["']?([A-Za-z0-9+\/_=-]{20,256})/i,
       fn value, _, _ ->
         literal?(value) && !technical_identifier?(value) && entropy(value) >= 4.0
       end}
    ]
  end

  defp technical_identifier?(value),
    do:
      Regex.match?(
        ~r/\A(?:[a-fA-F0-9]{32}|[a-fA-F0-9]{40}|[a-fA-F0-9]{64}|[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12})\z/,
        value
      )

  defp literal?(value) do
    value not in ["[REDACTED]", "null", "nil", "None", "true", "false"] &&
      !Regex.match?(
        ~r/\A(?:\$|\{|process\.env\.|os\.(?:environ|getenv)|System\.get_env|ENV\[)/,
        value
      )
  end

  defp jwt?(value) do
    case String.split(value, ".") do
      [header, payload, signature] ->
        with {:ok, decoded} <- Base.url_decode64(header, padding: false),
             {:ok, %{"alg" => algorithm} = object} <- Jason.decode(decoded),
             true <- is_binary(algorithm) && algorithm != "",
             true <- Map.get(object, "typ", "JWT") in ["JWT", "jwt"],
             {:ok, _} <- Base.url_decode64(payload, padding: false),
             {:ok, _} <- Base.url_decode64(signature, padding: false) do
          signature != "" || algorithm == "none"
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp entropy(value) do
    count = byte_size(value)

    value
    |> :binary.bin_to_list()
    |> Enum.frequencies()
    |> Enum.reduce(0.0, fn {_, frequency}, acc ->
      probability = frequency / count
      acc - probability * :math.log2(probability)
    end)
  end
end
