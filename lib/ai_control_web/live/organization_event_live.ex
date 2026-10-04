defmodule AiControlWeb.OrganizationEventLive do
  use AiControlWeb, :live_view

  alias AiControl.Audit
  alias AiControl.Audit.Serializer
  alias AiControlWeb.{ReportingHTML, ReportingLive}

  def mount(params, _, socket),
    do:
      {:ok,
       socket
       |> assign(page_title: "Event details", event_id: params["event_id"])
       |> ReportingLive.install(&refresh/1)
       |> refresh()}

  def handle_info({:organization_access_changed, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    with {:ok, event} <- Audit.get_event(socket.assigns.current_scope, socket.assigns.event_id),
         {:ok, events} <- Audit.request_events(socket.assigns.current_scope, event.request_id) do
      socket
      |> assign(event: event, evidence: Jason.encode!(Serializer.event(event), pretty: true))
      |> assign(:model_signal, model_signal(Serializer.data(event.data)))
      |> assign(:granite_status, granite_status(Serializer.data(event.data)))
      |> stream(:granite_checks, granite_checks(Serializer.data(event.data)), reset: true)
      |> stream(:chronology, events, reset: true)
    else
      _ ->
        socket
        |> put_flash(:error, "This event is unavailable in your organization.")
        |> redirect(to: ~p"/organizations/#{socket.assigns.current_scope.organization.id}/events")
    end
  end

  defp granite_status(data) do
    case Enum.find(Map.get(data, "guards", []), &(&1["guard"] == "granite")) do
      nil -> nil
      guard -> guard["status"]
    end
  end

  defp granite_checks(data) do
    guard = Enum.find(Map.get(data, "guards", []), &(&1["guard"] == "granite"))
    checks = if guard, do: get_in(guard, ["evidence", "checks"]) || [], else: []
    Enum.with_index(checks, fn check, index -> Map.put(check, :id, index) end)
  end

  def granite_trigger("earlier_findings"), do: "Earlier controls recorded findings"
  def granite_trigger("qwen_label"), do: "Qwen recorded an Unsafe or Controversial label"
  def granite_trigger("prompt_guard_score"), do: "Prompt Guard reached the suspicion threshold"
  def granite_trigger("high_risk_tool"), do: "High risk operation"
  def granite_trigger("privileged_resource"), do: "Privileged resource selector"
  def granite_trigger("retrieved_sources"), do: "Response uses retrieved sources"
  def granite_trigger("not_applicable"), do: "No retrieved sources; groundedness does not apply"
  def granite_trigger(_), do: "Request was not selected"

  def granite_outcome(%{"status" => "ok"} = check),
    do:
      "Score: #{check["score"]}. This criterion blocks on #{check["block_on"]}; result: #{check["interpretation"]}."

  def granite_outcome(%{"status" => "error"}),
    do: "Selected check unavailable. The request was blocked."

  def granite_outcome(_), do: "Skipped. This check did not run."

  defp model_signal(data) do
    guard = Enum.find(Map.get(data, "guards", []), &(&1["guard"] == "semantic"))
    evidence = guard && guard["evidence"]

    explain_signal(
      evidence,
      get_in(data, ["policy_evidence", "rules", "prompt_injection", "threshold"])
    )
  end

  defp explain_signal(%{"signal_kind" => "classifier_score", "windows" => windows}, threshold) do
    score = Enum.map(windows, & &1["score"]) |> Enum.max(fn -> nil end)

    "Llama Prompt Guard recorded a maximum malicious score of #{score || "Not recorded"} across #{length(windows)} windows. The recorded policy threshold was #{threshold || "Not recorded"}. This score is not a calibrated probability."
  end

  defp explain_signal(%{"signal_kind" => "label_mapping_binary", "windows" => windows}, _) do
    "Qwen recorded severity and category labels across #{length(windows)} windows. Injection matches require a selected severity and the Jailbreak category; the binary signal records that label mapping."
  end

  defp explain_signal(_, _), do: nil
end
