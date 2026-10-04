defmodule AiControl.Guards.Semantic.PromptGuard do
  @moduledoc "Pinned Prompt Guard scores with complete byte coverage; policy owns enforcement."
  @behaviour AiControl.Guards.Semantic.Provider

  alias AiControl.Guards.Semantic.Local
  alias AiControl.Security.{Detection, GuardResult, SemanticEvidence}

  @manifest_path Path.expand("../../../../sidecar/prompt_guard/models.v1.json", __DIR__)
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> Jason.decode!()
  def model_set, do: @manifest["model_set"]
  def revision, do: @manifest["revision"]

  def assess(fields, _context, snapshot, config) do
    started = System.monotonic_time()

    with {:ok, response} <- analyze(fields, "injection", config) do
      score = response["windows"] |> Enum.map(& &1["score"]) |> Enum.max(fn -> 0 end)

      detections =
        if score >= snapshot.settings["rules"]["prompt_injection"]["threshold"] do
          {:ok, detection} =
            Detection.new(%{
              guard: "semantic",
              category: "prompt_injection",
              rule_id: "semantic.prompt_guard.score.v1",
              confidence: score
            })

          [detection]
        else
          []
        end

      GuardResult.new(%{
        guard: "semantic",
        status: :ok,
        detections: detections,
        signals: %{"injection_score" => score},
        evidence:
          response
          |> Map.take(~w(model_set revision task windows))
          |> Map.put("signal_kind", "classifier_score"),
        duration_us:
          System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
      })
    end
  end

  @impl true
  def analyze(fields, "injection", config) do
    payload = %{
      task: "injection",
      timeout_ms: min(config[:semantic_timeout], 30_000),
      fields: Enum.with_index(fields, fn text, index -> %{field_index: index, text: text} end)
    }

    with {:ok, response} <- Local.request(:post, "/analyze", payload, transport(config)),
         true <- valid_response?(response, fields, "injection") do
      {:ok, response}
    else
      _ -> {:error, :guard_unavailable}
    end
  end

  def analyze(_, _, _), do: {:error, :guard_unavailable}

  @impl true
  def ready?(config) do
    config = config |> transport() |> Keyword.put(:semantic_timeout, config[:readiness_timeout])

    case Local.request(:get, "/ready", nil, config) do
      {:ok, %{"status" => "ready", "model_set" => set, "revision" => rev}} ->
        set == model_set() && rev == revision()

      _ ->
        false
    end
  end

  def valid_response?(
        %{
          "model_set" => set,
          "revision" => rev,
          "task" => "injection",
          "windows" => windows,
          "duration_us" => duration
        } = response,
        fields,
        "injection"
      ) do
    identity?(response, set, rev, duration) && windows?(windows) &&
      Enum.all?(windows, &SemanticEvidence.score_window?/1) &&
      Enum.all?(windows, &(&1["field_index"] < length(fields))) &&
      length(windows) ==
        length(Enum.uniq_by(windows, &Map.take(&1, ~w(field_index start_byte end_byte)))) &&
      Enum.all?(Enum.with_index(fields), fn {text, index} ->
        covered?(text, Enum.filter(windows, &(&1["field_index"] == index)))
      end)
  end

  def valid_response?(_, _, _), do: false

  defp identity?(response, set, rev, duration),
    do:
      map_size(response) == 5 && set == model_set() && rev == revision() && is_integer(duration) &&
        duration >= 0

  defp windows?(windows), do: is_list(windows) && length(windows) <= 128

  defp covered?("", [window]),
    do: window["start_byte"] == 0 && window["end_byte"] == 0 && window["score"] == 0

  defp covered?("", _), do: false

  defp covered?(text, windows) do
    windows
    |> Enum.sort_by(& &1["start_byte"])
    |> Enum.reduce_while(0, fn window, covered ->
      first = window["start_byte"]
      last = window["end_byte"]

      if first <= covered && last > first && last <= byte_size(text) &&
           String.valid?(binary_part(text, 0, first)) &&
           String.valid?(binary_part(text, first, last - first)) &&
           String.valid?(binary_part(text, last, byte_size(text) - last)),
         do: {:cont, max(covered, last)},
         else: {:halt, :invalid}
    end) == byte_size(text)
  end

  defp transport(config),
    do:
      config
      |> Keyword.put(:semantic_url, config[:prompt_guard_url])
      |> Keyword.put(:semantic_http_plug, config[:prompt_guard_http_plug])
end
