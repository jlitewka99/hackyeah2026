defmodule AiControl.Guards.Semantic.Local do
  @moduledoc "Pinned local Qwen transport with independently verified full UTF-8 coverage."
  @behaviour AiControl.Guards.Semantic.Provider

  alias AiControl.Security.SemanticEvidence

  @manifest_path Path.expand("../../../../sidecar/semantic/models.v1.json", __DIR__)
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> Jason.decode!()
  def model_set, do: @manifest["model_set"]
  def revision, do: @manifest["revision"]

  @impl true
  def analyze(fields, task, config) do
    payload = %{
      task: task,
      timeout_ms: min(config[:semantic_timeout], 30_000),
      fields:
        fields
        |> Enum.with_index()
        |> Enum.map(fn {text, index} -> %{field_index: index, text: text} end)
    }

    payload =
      if task == "moderation",
        do: Map.put(payload, :prompt, config[:semantic_prompt]),
        else: payload

    with true <- task != "moderation" || is_binary(config[:semantic_prompt]),
         {:ok, response} <- request(:post, "/analyze", payload, config),
         true <- valid_response?(response, fields, task) do
      {:ok, response}
    else
      _ -> {:error, :guard_unavailable}
    end
  end

  @impl true
  def ready?(config) do
    case request(
           :get,
           "/ready",
           nil,
           Keyword.put(config, :semantic_timeout, config[:readiness_timeout])
         ) do
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
          "task" => task,
          "windows" => windows,
          "duration_us" => duration
        } = response,
        fields,
        task
      ) do
    response_identity?(response, set, rev, duration) && windows_shape?(windows) &&
      Enum.all?(windows, &task_window?(&1, fields, task)) &&
      length(windows) ==
        length(Enum.uniq_by(windows, &Map.take(&1, ~w(field_index start_byte end_byte)))) &&
      all_fields_covered?(fields, windows, task)
  end

  def valid_response?(_, _, _), do: false

  defp response_identity?(response, set, rev, duration),
    do:
      map_size(response) == 5 && set == model_set() && rev == revision() && is_integer(duration) &&
        duration >= 0

  defp windows_shape?(windows),
    do:
      is_list(windows) && length(windows) <= 128 &&
        Enum.all?(windows, &SemanticEvidence.window?/1)

  defp task_window?(window, fields, task),
    do:
      window["field_index"] < length(fields) &&
        (task != "moderation" || "Jailbreak" not in window["categories"]) &&
        (task != "moderation" || window["refusal"] in ["Yes", "No"]) &&
        (task != "injection" || is_nil(window["refusal"]))

  defp all_fields_covered?(fields, windows, task),
    do:
      fields
      |> Enum.with_index()
      |> Enum.all?(fn {text, index} ->
        covered?(text, Enum.filter(windows, &(&1["field_index"] == index)), task)
      end)

  defp covered?("", [window], task),
    do:
      window["start_byte"] == 0 && window["end_byte"] == 0 &&
        (task == "moderation" || (window["severity"] == "Safe" && window["categories"] == []))

  defp covered?("", _windows, _task), do: false

  defp covered?(text, windows, _task) do
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

  defp request(method, path, payload, config) do
    options = [
      method: method,
      url: String.trim_trailing(config[:semantic_url], "/") <> path,
      retry: false,
      redirect: false,
      raw: true,
      connect_options: [timeout: config[:connect_timeout]],
      receive_timeout: config[:semantic_timeout],
      request_timeout: config[:semantic_timeout],
      into: fn {:data, chunk}, {request, response} ->
        size = Map.get(response.private, :semantic_bytes, 0) + byte_size(chunk)

        if size > config[:response_bytes] do
          {:halt, {request, Req.Response.put_private(response, :semantic_oversized, true)}}
        else
          response = Req.Response.put_private(response, :semantic_bytes, size)
          chunks = if is_list(response.body), do: response.body, else: []
          {:cont, {request, %{response | body: [chunk | chunks]}}}
        end
      end
    ]

    options = if payload, do: Keyword.put(options, :json, payload), else: options

    options =
      if config[:semantic_http_plug],
        do: Keyword.put(options, :plug, config[:semantic_http_plug]),
        else: options

    case Req.request(options) do
      {:ok, %{status: 200, private: private, body: chunks}} ->
        if Map.get(private, :semantic_oversized, false),
          do: {:error, :guard_unavailable},
          else: chunks |> Enum.reverse() |> IO.iodata_to_binary() |> Jason.decode()

      _ ->
        {:error, :guard_unavailable}
    end
  end
end
