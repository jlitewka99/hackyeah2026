defmodule AiControl.Guards.Ner do
  @moduledoc "Bounded local NER transport with content-free findings and independent byte validation."
  @behaviour AiControl.Gateway.Guard

  alias AiControl.Gateway.Content
  alias AiControl.Guards.Finding
  alias AiControl.Policies.Configuration
  alias AiControl.Security.{GuardResult, Validation}

  @impl true
  def assess(fields, _context, snapshot, config) do
    started = System.monotonic_time()
    selected = snapshot.settings["guards"]["ner"]["entities"]
    model_set = Map.get(snapshot.settings, "ner_model_set", "pl-nkjp.v1")
    revision = if model_set == "pl-nkjp.v2", do: "v2", else: "v1"

    payload = %{
      fields:
        fields
        |> Enum.with_index()
        |> Enum.map(fn {text, index} -> %{field_index: index, text: text} end)
    }

    payload =
      if model_set == "pl-nkjp.v1", do: payload, else: Map.put(payload, :model_set, model_set)

    with {:ok, %{"model_set" => ^model_set, "detections" => items} = response}
         when is_list(items) and map_size(response) == 2 <-
           request(:post, "/analyze", payload, config),
         true <- length(items) <= 20_000,
         true <- Enum.all?(items, &valid_item?(&1, fields, revision)) do
      findings =
        items
        |> Enum.filter(&(&1["type"] in selected))
        |> Enum.map(fn item ->
          Finding.new(
            "ner",
            "pii",
            "ner.#{item["type"]}.#{revision}",
            item["field_index"],
            item["start_byte"],
            item["end_byte"],
            item["score"]
          )
        end)

      GuardResult.new(%{
        guard: "ner",
        status: :ok,
        detections: findings,
        signals: %{"pii_count" => length(findings)},
        duration_us:
          System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
      })
    else
      _ -> {:error, :guard_unavailable}
    end
  end

  @impl true
  def ready?(config) do
    model_set = config[:ner_model_set] || "pl-nkjp.v1"
    path = if model_set == "pl-nkjp.v1", do: "/ready", else: "/ready?model_set=#{model_set}"

    case request(
           :get,
           path,
           nil,
           Keyword.put(config, :guard_timeout, config[:readiness_timeout])
         ) do
      {:ok, %{"status" => "ready", "model_set" => ^model_set}} -> true
      _ -> false
    end
  end

  defp valid_item?(
         %{
           "field_index" => index,
           "start_byte" => first,
           "end_byte" => last,
           "type" => type,
           "score" => score,
           "detector_id" => id
         } = item,
         fields,
         revision
       ) do
    map_size(item) == 6 && type in Configuration.ner_entities() && id == "ner.#{type}.#{revision}" &&
      Validation.score?(score) &&
      Content.locations_valid?(fields, [%{field_index: index, start_byte: first, end_byte: last}])
  end

  defp valid_item?(_, _, _), do: false

  defp request(method, path, payload, config) do
    options = [
      method: method,
      url: String.trim_trailing(config[:ner_url], "/") <> path,
      retry: false,
      redirect: false,
      raw: true,
      connect_options: [timeout: config[:connect_timeout]],
      receive_timeout: config[:guard_timeout],
      request_timeout: config[:guard_timeout],
      into: fn {:data, chunk}, {request, response} ->
        size = Map.get(response.private, :ner_bytes, 0) + byte_size(chunk)

        if size > config[:response_bytes] do
          {:halt, {request, Req.Response.put_private(response, :ner_oversized, true)}}
        else
          response = Req.Response.put_private(response, :ner_bytes, size)
          chunks = if is_list(response.body), do: response.body, else: []
          {:cont, {request, %{response | body: [chunk | chunks]}}}
        end
      end
    ]

    options = if payload, do: Keyword.put(options, :json, payload), else: options

    options =
      if config[:ner_http_plug],
        do: Keyword.put(options, :plug, config[:ner_http_plug]),
        else: options

    case Req.request(options) do
      {:ok, %{status: 200, private: private, body: chunks}} ->
        if Map.get(private, :ner_oversized, false),
          do: {:error, :guard_unavailable},
          else: chunks |> Enum.reverse() |> IO.iodata_to_binary() |> Jason.decode()

      _ ->
        {:error, :guard_unavailable}
    end
  end
end
