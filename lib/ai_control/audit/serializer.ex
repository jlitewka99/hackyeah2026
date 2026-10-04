defmodule AiControl.Audit.Serializer do
  @moduledoc "Explicit projection shared by rendered audit details and JSONL. Never serialize arbitrary data."
  alias AiControl.Audit.Event
  alias AiControl.Gateway.Measurements
  alias AiControl.Gateway.StreamEvidence
  alias AiControl.Knowledge.Evidence
  alias AiControl.Security.{GraniteEvidence, SemanticEvidence, Validation}
  alias AiControl.Tools.Catalog

  @fields ~w(id organization_id actor_type user_id agent_id api_key_id request_id run_id participant_id kind event_type target_id stage action policy_version policy_checksum rule_ids reason_codes fingerprint_digest fingerprint_key_id occurred_at duration_us)a
  @snapshot ~w(status role permissions agent_count model_count grants_fingerprint grants_fingerprint_key_id user_id previous_superadmin_id next_superadmin_id membership_id invitation_id policy_version_id policy_checksum policy_profile policy_source)

  def event(%Event{} = event), do: Map.take(event, @fields) |> Map.put(:data, data(event.data))

  def data(data) when is_map(data) do
    %{}
    |> put("approval", approval(data["approval"]))
    |> put("knowledge", knowledge(data["knowledge"]))
    |> put("operation", if(data["operation"] in ~w(chat models runs), do: data["operation"]))
    |> put("timings", if(Measurements.valid?(data["timings"]), do: data["timings"]))
    |> put("stream", if(StreamEvidence.valid?(data["stream"]), do: data["stream"]))
    |> put(
      "tool_execution",
      project(data["tool_execution"], ~w(execution_id workflow_id execution_status tool charged))
    )
    |> put(
      "budget",
      project(
        data["budget"],
        ~w(reservation_id window status reserved_tokens overrun cost currency cost_basis)
      )
      |> put(
        "usage",
        project(
          get_in(data, ["budget", "usage"]),
          ~w(prompt_tokens completion_tokens total_tokens)
        )
      )
    )
    |> put("guards", map_list(data["guards"], &guard/1))
    |> put("detections", map_list(data["detections"], &detection/1))
    |> put(
      "redactions",
      map_list(data["redactions"], &project(&1, ~w(field_index start_byte end_byte)))
    )
    |> put("failed_guards", codes(data["failed_guards"]))
    |> put("evaluated_guards", codes(data["evaluated_guards"]))
    |> put("policy_evidence", policy(data["policy_evidence"]))
    |> put("before", project(data["before"], @snapshot))
    |> put("after", project(data["after"], @snapshot))
    |> put("status", if(data["status"] in ~w(settled released), do: data["status"]))
  end

  def data(_), do: %{}

  defp approval(value) when is_map(value) do
    project(
      value,
      ~w(approval_id approval_status expires_at revision kind operation_request_id run_id participant_id)
    )
  end

  defp approval(_), do: nil

  defp knowledge(%{"operation" => operation, "resources" => resources}) do
    if operation in ~w(knowledge.list knowledge.read knowledge.search knowledge.created knowledge.updated knowledge.deleted knowledge.context) and
         Evidence.valid?(resources),
       do: %{"operation" => operation, "resources" => resources}
  end

  defp knowledge(_), do: nil

  defp guard(value) do
    value
    |> project(~w(guard status duration_us error_code))
    |> put(
      "signals",
      project(
        value["signals"],
        ~w(risk_score injection_score pii_count secret_count exploit_count)
      )
    )
    |> put("usage", project(value["usage"], ~w(prompt_tokens completion_tokens total_tokens)))
    |> put(
      "evidence",
      if(
        SemanticEvidence.valid?(value["evidence"]) or
          (value["guard"] == "granite" and GraniteEvidence.valid?(value["evidence"])),
        do: value["evidence"]
      )
    )
  end

  defp detection(value),
    do:
      project(value, ~w(guard category rule_id confidence))
      |> put("location", project(value["location"], ~w(field_index start_byte end_byte)))

  defp policy(nil), do: nil

  defp policy(value) when is_map(value) do
    %{}
    |> put("required_guards", codes(value["required_guards"]))
    |> put(
      "rules",
      if(is_map(value["rules"]),
        do:
          value["rules"]
          |> Enum.filter(fn {key, _} -> Validation.code?(key) end)
          |> Map.new(fn {key, rule} -> {key, project(rule, ~w(id action threshold))} end)
      )
    )
  end

  defp policy(_), do: nil

  defp project(value, keys) when is_map(value) do
    value
    |> Map.take(keys)
    |> Enum.filter(fn {key, item} -> safe_field?(key, item) end)
    |> Map.new()
  end

  defp project(_, _), do: %{}

  defp safe_field?(_, nil), do: true
  defp safe_field?("permissions", value), do: Validation.codes?(value)

  defp safe_field?(key, value)
       when key in ~w(field_index start_byte end_byte duration_us reserved_tokens prompt_tokens completion_tokens total_tokens pii_count secret_count exploit_count agent_count model_count revision),
       do: Validation.duration?(value)

  defp safe_field?(key, value) when key in ~w(confidence threshold risk_score injection_score),
    do: Validation.score?(value)

  defp safe_field?(key, value)
       when key in ~w(execution_id workflow_id reservation_id approval_id operation_request_id run_id participant_id user_id previous_superadmin_id next_superadmin_id membership_id invitation_id policy_version_id),
       do: Validation.uuid?(value)

  defp safe_field?(key, value) when key in ~w(grants_fingerprint policy_checksum),
    do: Validation.checksum?(value)

  defp safe_field?("overrun", value), do: is_boolean(value)
  defp safe_field?("charged", value), do: is_boolean(value)

  defp safe_field?("execution_status", value),
    do: value in ~w(pending dispatching completed rejected output_blocked failed uncertain)

  defp safe_field?("tool", value), do: Enum.any?(Catalog.all(), &(&1["name"] == value))

  defp safe_field?("cost_basis", value), do: value == "operator_estimate"

  defp safe_field?("cost", value) when value in ["not configured", "unavailable"], do: true

  defp safe_field?("cost", value),
    do: is_binary(value) && Regex.match?(~r/\A[0-9]+(?:\.[0-9]+)?\z/, value)

  defp safe_field?("currency", value),
    do: is_binary(value) && Regex.match?(~r/\A[A-Z]{3}\z/, value)

  defp safe_field?("expires_at", value),
    do: is_binary(value) and match?({:ok, _, 0}, DateTime.from_iso8601(value))

  defp safe_field?("window", value),
    do: is_binary(value) && match?({:ok, _, 0}, DateTime.from_iso8601(value))

  defp safe_field?(_, value), do: Validation.code?(value)
  defp codes(value), do: if(Validation.codes?(value), do: value)

  defp map_list(values, fun) when is_list(values),
    do: Enum.filter(values, &is_map/1) |> Enum.map(fun)

  defp map_list(_, _), do: nil
  defp put(map, _, nil), do: map
  defp put(map, _, value) when value == %{}, do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
