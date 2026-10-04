defmodule AiControl.Testing.ProcessExecutor do
  @moduledoc "Runs a fixed program in another BEAM VM; IPC never carries prompts, tokens or connection settings."
  alias AiControl.Background
  alias AiControl.Testing.Protocol

  @local_env ~w(GATEWAY_MODELS OLLAMA_BASE_URL NER_BASE_URL SEMANTIC_BASE_URL PROMPT_GUARD_BASE_URL TOKENIZER_BASE_URL OLLAMA_REASONING_EFFORT)

  def available? do
    match?({:ok, _}, database()) && match?({:ok, _}, command())
  end

  def database do
    url = Application.get_env(:ai_control, __MODULE__, [])[:database_url]
    uri = if is_binary(url), do: URI.parse(url), else: %URI{}
    name = if is_binary(uri.path), do: uri.path |> String.trim_leading("/") |> URI.decode()
    primary = AiControl.Repo.config()[:database]

    if valid_origin?(uri) && separate_database?(name, primary) do
      {:ok, url}
    else
      {:error, :runner_unavailable}
    end
  rescue
    _ -> {:error, :runner_unavailable}
  end

  defp valid_origin?(uri),
    do:
      uri.scheme in ~w(ecto postgres postgresql) && is_binary(uri.host) && is_nil(uri.fragment) &&
        uri.query in [nil, "ssl=true", "ssl=false"]

  defp separate_database?(name, primary),
    do:
      is_binary(name) && Regex.match?(~r/\A[a-zA-Z0-9_][a-zA-Z0-9_-]{0,62}\z/, name) &&
        name != primary

  def run(run, on_case) do
    with {:ok, url} <- database(),
         {:ok, {executable, args}} <- command(),
         {:ok, _, _} <- Background.authorized_run(run) do
      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:line, 16_384},
          {:args, args},
          {:env, environment(run, url)}
        ])

      try do
        await(port, run, on_case, System.monotonic_time(:millisecond) + 7_200_000, 0)
      after
        if Port.info(port), do: Port.close(port)
      end
    end
  rescue
    _ -> {:error, :runner_failed}
  end

  defp command do
    case Application.get_env(:ai_control, __MODULE__, [])[:executable] do
      path when is_binary(path) ->
        if File.regular?(path),
          do: {:ok, {path, ["eval", "AiControl.Testing.Runner.main()"]}},
          else: {:error, :runner_unavailable}

      nil ->
        if Code.ensure_loaded?(Mix) && System.find_executable("mix"),
          do:
            {:ok,
             {System.find_executable("mix"),
              ["run", "--no-start", "--no-compile", "-e", "AiControl.Testing.Runner.main()"]}},
          else: {:error, :runner_unavailable}
    end
  end

  defp environment(run, url) do
    allowed =
      Map.take(
        System.get_env(),
        @local_env ++ ~w(PATH HOME ASDF_DATA_DIR MIX_ENV TMPDIR MIX_HOME HEX_HOME)
      )

    values =
      Map.merge(allowed, %{
        "MIX_ENV" => mix_environment(),
        "AI_CONTROL_ISOLATED_RUNNER" => "1",
        "TEST_RUNNER_DATABASE_URL" => url,
        "AI_CONTROL_PRIMARY_DATABASE" => AiControl.Repo.config()[:database],
        "AI_CONTROL_TEST_SUITE" => run.spec["suite"],
        "AI_CONTROL_TEST_MODE" => run.spec["mode"],
        "DATABASE_URL" => url,
        "AUDIT_FINGERPRINT_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
        "SECRET_KEY_BASE" => Base.encode64(:crypto.strong_rand_bytes(64)),
        "PHX_HOST" => "localhost"
      })

    cleared = Map.new(System.get_env(), fn {key, _} -> {key, false} end)

    Map.merge(cleared, values)
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(key), if(value == false, do: false, else: String.to_charlist(value))}
    end)
  end

  defp mix_environment do
    if Code.ensure_loaded?(Mix), do: to_string(Mix.env()), else: "prod"
  end

  defp await(port, run, on_case, deadline, count) do
    with {:ok, _, _} <- Background.authorized_run(run),
         true <- System.monotonic_time(:millisecond) < deadline do
      ping(port)

      receive do
        {^port, {:data, {:eol, "AI_CONTROL_CASE " <> data}}} ->
          with true <- count < 1000,
               {:ok, row} <- Jason.decode(data),
               {:ok, safe} <- Protocol.case_result(row),
               :ok <- on_case.(safe) do
            await(port, run, on_case, deadline, count + 1)
          else
            _ -> {:error, :invalid_result}
          end

        {^port, {:data, {:eol, "AI_CONTROL_DONE"}}} ->
          if count > 0, do: {:ok, count}, else: {:error, :invalid_result}

        {^port, {:data, {:eol, "AI_CONTROL_UNAVAILABLE"}}} ->
          {:error, :runner_unavailable}

        {^port, {:exit_status, _}} ->
          {:error, :runner_failed}

        {^port, {:data, _}} ->
          await(port, run, on_case, deadline, count)
      after
        1000 -> await(port, run, on_case, deadline, count)
      end
    else
      false -> {:error, :runner_timeout}
      error -> error
    end
  end

  defp ping(port) do
    # The child may already have exited while its final IPC lines remain in our mailbox.
    Port.command(port, "ping\n")
  rescue
    ArgumentError -> :ok
  end
end
