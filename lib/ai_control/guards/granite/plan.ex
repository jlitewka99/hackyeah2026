defmodule AiControl.Guards.Granite.Plan do
  @moduledoc "Internal selection after deterministic controls and redaction. Selectors never grant access."
  alias AiControl.Guards.Granite.{Criteria, Model}
  alias AiControl.{Tools, Workflows}
  alias AiControl.Tools.{Catalog, Sandbox, ToolRequest}

  def build(fields, context, policy, config) do
    settings = policy.settings["granite"]
    value = config[:granite_value]
    actions = actions(value, context.stage, config)
    suspicion = suspicion(config, settings)
    documents = documents(config, context.stage)

    settings["criteria"]
    |> Enum.sort()
    |> Enum.filter(fn {_, criterion} -> criterion["enabled"] end)
    |> Enum.flat_map(fn {id, criterion} ->
      selections(
        criterion["task"],
        actions,
        suspicion,
        documents,
        fields,
        context,
        settings,
        config
      )
      |> Enum.map(fn {trigger, target, docs, index, action} ->
        check = %{
          "criterion_id" => id,
          "criterion_hash" => Criteria.hash(criterion),
          "task" => criterion["task"],
          "trigger" => trigger,
          "status" => "skipped",
          "score" => nil,
          "block_on" => criterion["block_on"],
          "interpretation" => "skipped",
          "duration_us" => 0,
          "usage" => nil,
          "action_index" => index
        }

        %{evidence: check, criterion: criterion, target: target, documents: docs, action: action}
      end)
    end)
  end

  def evidence(checks),
    do: %{"model" => Model.name(), "digest" => Model.digest(), "checks" => checks}

  def selected?(check), do: check.evidence["trigger"] not in ~w(not_selected not_applicable)

  defp selections("suspicious_input", _, suspicion, _, fields, %{stage: :input}, settings, config) do
    if settings["suspicious_input"] and not is_nil(suspicion) and
         config[:content_adapter] in [nil, AiControl.Tools.Content],
       do: [{suspicion, fields, [], nil, nil}],
       else: skipped()
  end

  defp selections("groundedness", _, _, documents, fields, %{stage: :output}, _, config) do
    if documents != [] and is_nil(config[:content_adapter]),
      do: [{"retrieved_sources", fields, documents, nil, nil}],
      else: skipped("not_applicable")
  end

  defp selections("tool_action", actions, _, _, _, _, settings, _) do
    selected =
      actions
      |> Enum.with_index()
      |> Enum.flat_map(fn {action, index} ->
        case tool_trigger(action, settings) do
          nil -> []
          trigger -> [{trigger, action, [], index, action}]
        end
      end)

    if selected == [], do: skipped(), else: selected
  end

  defp selections(_, _, _, _, _, _, _, _), do: skipped()
  defp skipped(reason \\ "not_selected"), do: [{reason, nil, [], nil, nil}]

  defp actions(%{"tool" => tool, "arguments" => args}, :input, config) do
    if config[:tool_request], do: [%{"tool" => tool, "arguments" => args}], else: []
  end

  defp actions(%{"choices" => [%{"message" => message}]}, :output, config) do
    if is_nil(config[:content_adapter]) do
      Enum.map(Map.get(message, "tool_calls", []), fn call ->
        %{
          "tool" => call["function"]["name"],
          "arguments" => Jason.decode!(call["function"]["arguments"])
        }
      end)
    else
      []
    end
  end

  defp actions(_, _, _), do: []

  defp tool_trigger(action, settings) do
    resources = settings["privileged_resources"]

    kind =
      %{
        "file.read" => {"paths", "path"},
        "file.write" => {"paths", "path"},
        "file.delete" => {"paths", "path"},
        "database.select" => {"tables", "table"},
        "http.get" => {"endpoints", "url"},
        "email.send" => {"recipients", "recipient"},
        "command.run" => {"commands", "command"}
      }[action["tool"]]

    cond do
      action["tool"] in settings["high_risk_tools"] ->
        "high_risk_tool"

      kind && action["arguments"][elem(kind, 1)] in resources[elem(kind, 0)] ->
        "privileged_resource"

      true ->
        nil
    end
  end

  defp suspicion(config, settings) do
    previous = config[:granite_previous] || []

    cond do
      config[:granite_findings] ->
        "earlier_findings"

      Enum.any?(previous, fn result ->
        Enum.any?(
          Map.get(result.evidence, "windows", []),
          &(&1["severity"] in ~w(Controversial Unsafe))
        )
      end) ->
        "qwen_label"

      Enum.any?(previous, fn result ->
        result.evidence["signal_kind"] == "classifier_score" and
            Map.get(result.signals, "injection_score", 0) >= settings["suspicious_threshold"]
      end) ->
        "prompt_guard_score"

      true ->
        nil
    end
  end

  defp documents(config, :output) do
    if (config[:knowledge_sources] || []) == [] do
      []
    else
      # The server inserted this exact penultimate message; use its post-redaction bytes.
      case Enum.at(config[:granite_messages] || [], -2) do
        %{"name" => "retrieved_context", "content" => payload} ->
          decode_documents(payload)

        _ ->
          :unavailable
      end
    end
  end

  defp documents(_, _), do: []

  defp decode_documents(payload) do
    case Jason.decode(payload) do
      {:ok, %{"source_type" => "retrieved_data", "sources" => sources}} when is_list(sources) ->
        sources

      _ ->
        :unavailable
    end
  end

  def authorize(checks, policy, config) do
    if Enum.any?(checks, &selected?/1) do
      data = Workflows.judging_context(config[:granite_identity], policy, config[:run_context])

      Enum.map(checks, &attach_check_context(&1, data, policy, config))
    else
      checks
    end
  end

  defp attach_check_context(check, data, policy, config) do
    with {:ok, context} <- data,
         {:ok, action} <- authorized_action(check.action, policy, config) do
      Map.put(check, :data, Map.merge(context, action))
    else
      _ -> Map.put(check, :data, :unavailable)
    end
  end

  defp authorized_action(nil, _, _), do: {:ok, %{}}

  defp authorized_action(action, policy, config) do
    with {:ok, request} <- ToolRequest.new(config[:granite_identity], action, policy),
         request = %{request | run_context: config[:run_context]},
         :ok <- Tools.authorize(request),
         [{server, _}] <- Registry.lookup(AiControl.Tools.Registry, request.organization_id),
         {:ok, resources} <- Sandbox.preflight(server, request) do
      grant = resources.grant

      permitted =
        Map.new(
          ~w(paths tables recipients commands)a,
          &{Atom.to_string(&1), Map.get(grant, &1, [])}
        )
        |> Map.put("endpoints", Map.keys(Map.get(grant, :endpoints, %{})))

      {:ok,
       %{
         "permitted_resources" => permitted,
         "tool_definition" => Enum.find(Catalog.all(), &(&1["name"] == action["tool"]))
       }}
    else
      _ -> {:error, :guard_unavailable}
    end
  end
end
