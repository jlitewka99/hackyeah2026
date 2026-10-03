defmodule AiControl.Guards.SecretTest do
  use ExUnit.Case, async: true

  alias AiControl.Guards.Secret

  test "provider, PEM, JWT, labels and connection credentials are detected offline" do
    header = Base.url_encode64(~s({"alg":"HS256","typ":"JWT"}), padding: false)
    payload = Base.url_encode64(~s({"sub":"synthetic"}), padding: false)
    signature = Base.url_encode64("synthetic-signature", padding: false)

    for {id, text} <- [
          {"pem", "-----BEGIN PRIVATE KEY-----\nsynthetic\n-----END PRIVATE KEY-----"},
          {"pem", "-----BEGIN OPENSSH PRIVATE KEY-----"},
          {"pem", "-----BEGIN PRIVATE KEY-----\n" <> String.duplicate("x", 70_000)},
          {"aws", "AKIA" <> String.duplicate("A", 16)},
          {"github", "ghp_" <> String.duplicate("a", 36)},
          {"google", "AIza" <> String.duplicate("a", 35)},
          {"jwt", "#{header}.#{payload}.#{signature}"},
          {"password", "password='synthetic-value'"},
          {"bearer", "Authorization: Bearer synthetic-value"},
          {"connection", "postgresql://user:synthetic-value@localhost/database"},
          {"entropy", "token = aZ9pR2mL7qT4xB8cN1vH6sW3"}
        ] do
      {:ok, result} = Secret.assess(["😀 " <> text], nil, nil, [])
      assert Enum.any?(result.detections, &(&1.rule_id == "secret.#{id}.v1")), "Missing #{id}"
      refute inspect(result) =~ "synthetic-value"
    end
  end

  test "safe hashes, UUIDs, code references and invalid JWTs are not secrets" do
    for text <- [
          "sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "a40ec6d3-8b62-4c18-b433-453d10f438e2",
          "token = a40ec6d3-8b62-4c18-b433-453d10f438e2",
          "token = 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "password = System.get_env(\"DB_PASSWORD\")",
          "api_key = process.env.KEY",
          "password = null",
          "api_key = [REDACTED]",
          "abcd.efgh.ijkl",
          "aaaa.bbbb",
          "word word word word"
        ] do
      {:ok, result} = Secret.assess([text], nil, nil, [])
      assert result.detections == []
    end
  end

  test "JWS supports arbitrary types and detached payloads but validates all segments" do
    signed = Base.url_encode64(~s({"alg":"HS256","typ":"JOSE"}), padding: false)
    unsigned = Base.url_encode64(~s({"alg":"none"}), padding: false)
    bad_type = Base.url_encode64(~s({"alg":"HS256","typ":123}), padding: false)
    signature = Base.url_encode64("synthetic-signature", padding: false)

    for value <- ["#{signed}.YQ.#{signature}", "#{signed}..#{signature}", "#{unsigned}.."] do
      {:ok, result} = Secret.assess(["Token: #{value}."], nil, nil, [])
      assert Enum.any?(result.detections, &(&1.rule_id == "secret.jwt.v1"))
    end

    for value <- [
          "#{signed}.YQ.",
          "#{signed}.YQ.#{signature}.extra",
          "prefix.#{signed}.YQ.#{signature}",
          "#{bad_type}.YQ.#{signature}",
          "#{signed}.a.#{signature}",
          "#{signed}.YQ.a"
        ] do
      {:ok, result} = Secret.assess([value], nil, nil, [])
      assert result.detections == []
    end
  end
end
