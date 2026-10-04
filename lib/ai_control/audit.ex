defmodule AiControl.Audit do
  @moduledoc "Synchronous, tenant-scoped audit writes with an explicit content-free serializer."
  import Ecto.Query

  alias AiControl.Audit.{Event, Filters, WorkflowVisibility}
  alias AiControl.Budgets.Usage
  alias AiControl.Gateway.Measurements
  alias AiControl.Gateway.StreamEvidence
  alias AiControl.Knowledge.Evidence
  alias AiControl.Organizations
  alias AiControl.Organizations.{Access, Grants}
  alias AiControl.Policies.Configuration
  alias AiControl.Policy.Snapshot
  alias AiControl.Repo

  alias AiControl.Security.{
    Decision,
    Fingerprint,
    SecurityAssessment,
    SecurityContext,
    Validation
  }

  alias AiControl.Tools.Catalog
  alias AiControl.Workflows

  @policy_events ~w(policy.version_created policy.activated policy.rolled_back policy.inheritance_restored)
  @admin_events ~w(organization.created organization.status_changed member.access_changed member.removed superadmin.transferred invitation.issued invitation.revoked invitation.accepted invitation.delivery_failed) ++
                  @policy_events
  @snapshot_fields ~w(status role permissions agent_count model_count grants_fingerprint grants_fingerprint_key_id user_id previous_superadmin_id next_superadmin_id membership_id invitation_id policy_version_id policy_checksum policy_profile policy_source)a

  @workflow_codes ~w(workflow_context_required workflow_terminal workflow_conflict workflow_limit_exceeded workflow_unavailable approval_required approval_rejected approval_expired approval_conflict approval_used approval_unavailable)
  @gateway_codes @workflow_codes ++
                   ~w(completed stream_ready stream_cancelled stream_delivery_timeout stream_unavailable invalid_request input_too_large forbidden agent_not_allowed model_not_allowed policy_unavailable rate_limited capacity_exceeded guard_unavailable policy_blocked redaction_unavailable audit_unavailable upstream_timeout upstream_unavailable upstream_rejected upstream_invalid_response response_too_large model_unavailable model_digest_mismatch request_budget_exceeded token_budget_exceeded budget_unavailable budget_conflict tokenizer_unavailable knowledge_disabled knowledge_write_disabled knowledge_conflict)
  def gateway_codes, do: @gateway_codes

  def record_approval(identity, record, status) do
    with true <- status in AiControl.Approvals.statuses(),
         {:ok, attrs} <- gateway_identity(identity) do
      pending? = status == "pending"

      persist(
        struct!(
          Event,
          Map.merge(attrs, %{
            request_id: record.claim_request_id || record.operation_request_id,
            run_id: record.run_id,
            participant_id: record.participant_id,
            kind: if(pending?, do: :decision, else: :gateway),
            event_type: "approval." <> status,
            target_id: record.id,
            stage: :input,
            action: if(pending?, do: :review),
            policy_version: record.policy_version,
            policy_checksum: record.policy_checksum,
            reason_codes: [if(pending?, do: "policy.review", else: "approval." <> status)],
            fingerprint_digest: record.prepared_digest,
            fingerprint_key_id: record.fingerprint_key_id,
            occurred_at: AiControl.Approvals.now(),
            data: %{approval: AiControl.Approvals.evidence(record)}
          })
        )
      )
    else
      _ -> {:error, :invalid_audit_data}
    end
  end

  @tool_codes @workflow_codes ++
                ~w(completed dispatching invalid_request input_too_large forbidden agent_not_allowed tool_not_allowed invalid_tool_request invalid_tool_arguments tool_request_too_large tool_resource_not_allowed tool_resource_not_found tool_redirect_blocked tool_upstream_unavailable tool_invalid_result tool_unavailable tool_timeout tool_cancelled tool_interrupted tool_execution_exists idempotency_conflict tool_budget_exceeded request_budget_exceeded budget_unavailable policy_unavailable guard_unavailable policy_blocked redaction_unavailable audit_unavailable capacity_exceeded rate_limited)

  def record_knowledge(identity, request_id, operation, code, policy, resources) do
    with true <-
           operation in ~w(knowledge.list knowledge.read knowledge.search knowledge.created knowledge.updated knowledge.deleted knowledge.context),
         true <-
           code in (@gateway_codes ++
                      ~w(knowledge_disabled knowledge_write_disabled knowledge_conflict)),
         true <- Validation.uuid?(request_id) and Evidence.valid?(resources),
         true <- is_nil(policy) or Snapshot.valid?(policy),
         {:ok, attrs} <- gateway_identity(identity) do
      persist(
        struct!(
          Event,
          Map.merge(attrs, %{
            request_id: request_id,
            kind: :gateway,
            event_type: operation,
            target_id: request_id,
            stage: :input,
            reason_codes: [code],
            occurred_at: DateTime.utc_now(),
            policy_version: if(policy, do: policy.version),
            policy_checksum: if(policy, do: policy.checksum),
            data: %{knowledge: %{operation: operation, resources: resources}}
          })
        )
      )
    else
      _ -> {:error, :invalid_audit_data}
    end
  end

  def record_tool(identity, request_id, type, code, duration, policy, evidence) do
    with true <-
           type in ~w(tool.completed tool.dispatching tool.rejected tool.output_blocked tool.failed tool.uncertain),
         true <-
           code in @tool_codes && Validation.uuid?(request_id) && Validation.duration?(duration),
         true <- is_nil(policy) || Snapshot.valid?(policy),
         true <- tool_evidence?(type, evidence),
         {:ok, attrs} <- gateway_identity(identity) do
      event =
        struct!(
          Event,
          Map.merge(Map.merge(attrs, Workflows.audit_reference(identity, request_id)), %{
            request_id: request_id,
            kind: :gateway,
            event_type: type,
            target_id: if(evidence, do: evidence.execution_id, else: request_id),
            stage: if(type in ~w(tool.completed tool.output_blocked), do: :output, else: :input),
            policy_version: if(policy, do: policy.version),
            policy_checksum: if(policy, do: policy.checksum),
            reason_codes: [code],
            occurred_at: DateTime.utc_now(),
            duration_us: duration,
            data: if(evidence, do: %{tool_execution: evidence}, else: %{})
          })
        )

      persist(event)
    else
      _ -> {:error, :invalid_audit_data}
    end
  end

  def record_workflow(identity, run_id, participant_id, event, reason) do
    with true <- event in ~w(created delegated completed stopped limit_exceeded interrupted),
         true <-
           Validation.uuid?(run_id) &&
             (is_nil(participant_id) || Validation.uuid?(participant_id)),
         true <-
           is_nil(reason) ||
             reason in ~w(max_duration_seconds max_calls max_tokens tool_calls max_delegation_depth max_repeated_actions process_interrupted),
         {:ok, attrs} <- gateway_identity(identity) do
      persist(
        struct!(
          Event,
          Map.merge(attrs, %{
            request_id: Ecto.UUID.generate(),
            run_id: run_id,
            participant_id: participant_id,
            kind: :gateway,
            event_type: "workflow." <> event,
            target_id: run_id,
            stage: :input,
            reason_codes: if(reason, do: [reason], else: []),
            occurred_at: DateTime.utc_now(),
            data: %{}
          })
        )
      )
    else
      _ -> {:error, :invalid_audit_data}
    end
  end

  defp tool_evidence?("tool.rejected", nil), do: true

  defp tool_evidence?(
         type,
         %{
           execution_id: id,
           workflow_id: workflow,
           execution_status: status,
           tool: tool,
           charged: charged
         } = evidence
       ) do
    map_size(evidence) == 5 && type == "tool." <> status &&
      charged == status not in ~w(pending rejected) &&
      Validation.uuid?(id) && Validation.uuid?(workflow) &&
      status in ~w(pending dispatching completed rejected output_blocked failed uncertain) &&
      Enum.any?(Catalog.all(), &(&1["name"] == tool)) && is_boolean(charged)
  end

  defp tool_evidence?(_, _), do: false

  @doc "Content-free terminal evidence from the gateway's verified identity adapter."
  def record_gateway(
        identity,
        request_id,
        code,
        duration_us,
        policy \\ nil,
        stage \\ :input,
        budget \\ nil,
        observation \\ nil
      ) do
    with true <-
           Validation.uuid?(request_id) && code in @gateway_codes &&
             Validation.duration?(duration_us) && stage in [:input, :output],
         true <- is_nil(policy) || Snapshot.valid?(policy),
         true <- budget_evidence?(budget),
         true <- observation?(observation),
         {:ok, attrs} <- gateway_identity(identity) do
      event =
        struct!(
          Event,
          Map.merge(Map.merge(attrs, Workflows.audit_reference(identity, request_id)), %{
            request_id: request_id,
            kind: :gateway,
            event_type: gateway_event_type(code),
            target_id: request_id,
            stage: stage,
            policy_version: if(policy, do: policy.version),
            policy_checksum: if(policy, do: policy.checksum),
            reason_codes: [code],
            occurred_at: DateTime.utc_now(),
            duration_us: duration_us,
            data: gateway_data(budget, observation)
          })
        )

      persist(event)
    else
      _ -> {:error, :invalid_audit_data}
    end
  end

  defp observation?(nil), do: true

  defp observation?(%{operation: "chat", timings: timings, stream: stream} = value),
    do: map_size(value) == 3 && Measurements.valid?(timings) && StreamEvidence.valid?(stream)

  defp observation?(%{operation: operation, timings: timings} = value),
    do: map_size(value) == 2 && operation in ~w(chat models runs) && Measurements.valid?(timings)

  defp observation?(_), do: false

  defp gateway_data(budget, observation) do
    data = if budget, do: %{budget: budget}, else: %{}
    if observation, do: Map.merge(data, observation), else: data
  end

  defp budget_evidence?(nil), do: true

  defp budget_evidence?(
         %{
           reservation_id: id,
           window: window,
           status: status,
           reserved_tokens: tokens,
           usage: usage,
           overrun: overrun,
           cost: cost,
           currency: currency
         } = data
       ) do
    map_size(data) == 8 && budget_identity?(id, window, status) &&
      budget_values?(tokens, usage, overrun) && budget_cost?(cost) && budget_currency?(currency)
  end

  defp budget_evidence?(_), do: false

  defp budget_identity?(id, window, status) do
    Validation.uuid?(id) && is_binary(window) &&
      match?({:ok, _, _}, DateTime.from_iso8601(window)) &&
      status in ~w(admitted reserved dispatching uncertain settled released)
  end

  defp budget_values?(tokens, usage, overrun) do
    is_integer(tokens) && tokens >= 0 && is_boolean(overrun) &&
      (is_nil(usage) || match?({:ok, ^usage}, Usage.normalize(usage)))
  end

  defp budget_cost?(cost) when cost in ["not configured", "unavailable"], do: true
  defp budget_cost?(cost) when is_binary(cost), do: Regex.match?(~r/\A\d+(\.\d+)?\z/, cost)
  defp budget_cost?(_), do: false
  defp budget_currency?(nil), do: true

  defp budget_currency?(currency) when is_binary(currency),
    do: Regex.match?(~r/\A[A-Z]{3}\z/, currency)

  defp budget_currency?(_), do: false

  def record_budget_reconciliation(scope, id, status) when status in ~w(settled released) do
    with {:ok, current} <- Access.authorize(scope, "budgets.manage") do
      persist(%Event{
        organization_id: current.organization.id,
        actor_type: :user,
        user_id: current.user.id,
        request_id: Ecto.UUID.generate(),
        kind: :administrative,
        event_type: "budget.reconciled",
        target_id: id,
        stage: :administrative,
        occurred_at: DateTime.utc_now(),
        data: %{status: status}
      })
    end
  end

  defp gateway_event_type("completed"), do: "gateway.completed"
  defp gateway_event_type("stream_ready"), do: "gateway.stream_ready"
  defp gateway_event_type("stream_cancelled"), do: "gateway.cancelled"

  defp gateway_event_type(code)
       when code in ~w(stream_delivery_timeout stream_unavailable policy_unavailable guard_unavailable audit_unavailable upstream_timeout upstream_unavailable upstream_rejected upstream_invalid_response response_too_large model_unavailable model_digest_mismatch),
       do: "gateway.failed"

  defp gateway_event_type(_), do: "gateway.rejected"

  defp gateway_identity(%AiControl.ApiKeys.Principal{} = identity) do
    if Enum.all?(
         [identity.organization_id, identity.agent_id, identity.api_key_id],
         &Validation.uuid?/1
       ),
       do:
         {:ok,
          %{
            organization_id: identity.organization_id,
            actor_type: :agent,
            agent_id: identity.agent_id,
            api_key_id: identity.api_key_id
          }},
       else: {:error, :invalid_audit_data}
  end

  defp gateway_identity(%AiControl.Accounts.Scope{organization: %{id: org}, user: %{id: user}}) do
    if Validation.uuid?(org) && Validation.uuid?(user),
      do: {:ok, %{organization_id: org, actor_type: :user, user_id: user}},
      else: {:error, :invalid_audit_data}
  end

  defp gateway_identity(_), do: {:error, :invalid_audit_data}

  def record_platform(%AiControl.Accounts.Scope{user: %{id: id}}, event_type, attrs) do
    with true <- event_type in (@policy_events -- ["policy.inheritance_restored"]),
         true <- admin_attrs?(attrs),
         %{organizer: true} = user <- Repo.get(AiControl.Accounts.User, id, log: false) do
      persist(%Event{
        scope: :platform,
        user_id: user.id,
        actor_type: :user,
        request_id: Ecto.UUID.generate(),
        kind: :administrative,
        event_type: event_type,
        target_id: attrs.target_id,
        stage: :administrative,
        occurred_at: DateTime.utc_now(),
        data: Map.delete(attrs, :target_id)
      })
    else
      _ -> {:error, :invalid_audit_data}
    end
  end

  def record_platform(_, _, _), do: {:error, :invalid_audit_data}

  def list_platform_events(%AiControl.Accounts.Scope{user: %{id: id}}) do
    case Repo.get(AiControl.Accounts.User, id, log: false) do
      %{organizer: true} ->
        {:ok,
         Repo.all(
           from(e in Event,
             where: e.scope == :platform,
             order_by: [desc: e.occurred_at],
             limit: 200
           ),
           log: false
         )}

      _ ->
        {:error, :forbidden}
    end
  end

  def list_platform_events(_), do: {:error, :forbidden}

  def record_decision(context, assessment, decision),
    do: decision_event(context, assessment, decision, nil)

  def record_phase_decision(context, assessment, decision, guards) do
    if is_list(guards) && guards != [] &&
         Enum.all?(guards, &(&1 in Configuration.guards(6))),
       do: decision_event(context, assessment, decision, guards),
       else: {:error, :invalid_audit_data}
  end

  defp decision_event(context, assessment, decision, guards) do
    if valid_decision?(context, assessment, decision) do
      event = %Event{
        id: assessment.id,
        organization_id: context.organization_id,
        actor_type: context.actor_type,
        user_id: context.user_id,
        agent_id: context.agent_id,
        api_key_id: context.api_key_id,
        request_id: context.request_id,
        run_id: context.run_id,
        participant_id: context.participant_id,
        kind: :decision,
        event_type: "security.decision",
        target_id: assessment.id,
        stage: context.stage,
        action: decision.action,
        policy_version: decision.policy_version,
        policy_checksum: decision.policy_checksum,
        rule_ids: decision.rule_ids,
        reason_codes: decision.reason_codes,
        occurred_at: context.occurred_at,
        duration_us: assessment.duration_us,
        data: phase_evidence(assessment_data(assessment, decision), guards)
      }

      persist(with_fingerprint(event, context.fingerprint))
    else
      {:error, :invalid_audit_data}
    end
  end

  @doc "For authorized domain mutations inside their transaction; identity is always refreshed."
  def record_admin(scope, event_type, attrs) do
    with true <- event_type in @admin_events,
         true <- admin_attrs?(attrs),
         {:ok, current} <- Organizations.refresh_scope(scope) do
      event = %Event{
        organization_id: current.organization.id,
        user_id: current.user.id,
        actor_type: :user,
        request_id: Ecto.UUID.generate(),
        kind: :administrative,
        event_type: event_type,
        target_id: attrs.target_id,
        stage: :administrative,
        occurred_at: DateTime.utc_now(),
        data: Map.delete(attrs, :target_id)
      }

      persist(event)
    else
      _ -> {:error, :invalid_audit_data}
    end
  end

  def access_snapshot(organization_id, member) do
    grants = member.grants || %Grants{}

    {:ok, fingerprint} =
      Fingerprint.content(
        organization_id,
        :administrative,
        grants
        |> Grants.attrs()
        |> Map.new(fn {key, values} -> {key, Enum.sort(values)} end)
        |> :erlang.term_to_binary()
      )

    %{
      role: Atom.to_string(member.role),
      permissions: Enum.sort(grants.permissions),
      agent_count: length(grants.agents),
      model_count: length(grants.models),
      grants_fingerprint: fingerprint.digest,
      grants_fingerprint_key_id: fingerprint.key_id,
      user_id: member.user_id
    }
  end

  def list_events(scope, opts \\ []) do
    with {:ok, current} <- Access.authorize(scope, "events.read"),
         true <- is_list(opts) && Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:limit, :offset])),
         limit = Keyword.get(opts, :limit, 50),
         offset = Keyword.get(opts, :offset, 0),
         true <- is_integer(limit) && limit in 1..200 && is_integer(offset) && offset >= 0 do
      {:ok,
       from(e in Event,
         where: e.organization_id == ^current.organization.id,
         order_by: [desc: e.occurred_at, desc: e.id],
         limit: ^limit,
         offset: ^offset
       )
       |> WorkflowVisibility.query(current)
       |> Repo.all(log: false)}
    else
      {:error, _} -> {:error, :forbidden}
      _ -> {:error, :invalid_audit_data}
    end
  end

  def get_event(scope, id) do
    with {:ok, current} <- Access.authorize(scope, "events.read"),
         {:ok, id} <- Ecto.UUID.cast(id),
         %Event{} = event <-
           Repo.one(
             WorkflowVisibility.query(
               from(e in Event,
                 where: e.id == ^id and e.organization_id == ^current.organization.id
               ),
               current
             ),
             log: false
           ) do
      {:ok, event}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      _ -> {:error, :not_found}
    end
  end

  def page_events(scope, filters) do
    with {:ok, current} <- Access.authorize(scope, "events.read") do
      events =
        Filters.query(current.organization.id, filters)
        |> WorkflowVisibility.query(current)
        |> Filters.after_cursor(filters.cursor)
        |> order_by([e], desc: e.occurred_at, desc: e.id)
        |> limit(51)
        |> Repo.all(log: false)

      page = Enum.take(events, 50)

      {:ok,
       %{
         events: page,
         next: if(length(events) > 50, do: Filters.cursor(List.last(page)))
       }}
    end
  end

  def request_events(scope, request_id) do
    with {:ok, current} <- Access.authorize(scope, "events.read"),
         {:ok, id} <- Ecto.UUID.cast(request_id) do
      {:ok,
       from(e in Event,
         where: e.organization_id == ^current.organization.id and e.request_id == ^id,
         order_by: [asc: e.occurred_at, asc: e.id]
       )
       |> WorkflowVisibility.query(current)
       |> Repo.all(log: false)}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp valid_decision?(context, assessment, decision),
    do:
      SecurityContext.valid?(context) && SecurityAssessment.valid?(assessment) &&
        Decision.valid?(decision) && matching_identity?(context, assessment, decision)

  defp matching_identity?(context, assessment, decision) do
    identity = {context.assessment_id, context.request_id, context.stage}

    identity == {assessment.id, assessment.request_id, assessment.stage} &&
      identity == {decision.assessment_id, decision.request_id, decision.stage} &&
      {context.policy_version, context.policy_checksum} ==
        {decision.policy_version, decision.policy_checksum}
  end

  defp assessment_data(assessment, decision) do
    %{
      guards:
        Enum.map(assessment.results, fn result ->
          Map.take(result, [
            :guard,
            :status,
            :signals,
            :duration_us,
            :error_code,
            :usage,
            :evidence
          ])
        end),
      detections:
        Enum.map(
          assessment.detections,
          &Map.take(&1, [:guard, :category, :rule_id, :confidence, :location])
        ),
      failed_guards: assessment.failed_guards,
      redactions: decision.redactions,
      policy_evidence: %{
        required_guards:
          Snapshot.required_guards(decision.policy, decision.stage, assessment.results),
        settings: audit_settings(decision.policy.settings),
        rules:
          Map.new(decision.policy.rules, fn {category, rule} ->
            {category,
             %{id: rule.id, action: rule.action, threshold: Map.get(rule, :threshold, 0)}}
          end)
      }
    }
  end

  defp audit_settings(%{"schema_version" => 6} = settings), do: Map.delete(settings, "granite")
  defp audit_settings(settings), do: settings

  defp phase_evidence(data, nil), do: data
  defp phase_evidence(data, guards), do: Map.put(data, :evaluated_guards, guards)

  defp with_fingerprint(event, nil), do: event

  defp with_fingerprint(event, fingerprint),
    do: %{event | fingerprint_digest: fingerprint.digest, fingerprint_key_id: fingerprint.key_id}

  defp persist(event) do
    if Repo.in_transaction?() do
      persist_event(event)
    else
      result = Repo.transact(fn -> persist_event(event) end)
      if match?({:ok, _}, result) && event.organization_id, do: notify(event.organization_id)
      result
    end
  end

  defp persist_event(event) do
    event = %{event | id: event.id || Ecto.UUID.generate()}

    with {:ok, _} <-
           Repo.insert(Event.changeset(event),
             on_conflict: :nothing,
             conflict_target: :id,
             mode: :savepoint,
             log: false
           ),
         stored = Repo.get!(Event, event.id, log: false),
         true <- comparable(event) == comparable(stored) do
      {:ok, stored}
    else
      false -> {:error, :audit_conflict}
      _ -> {:error, :audit_unavailable}
    end
  rescue
    _ -> {:error, :audit_unavailable}
  end

  def notify(organization_id) do
    if !Repo.in_transaction?() && Process.whereis(AiControl.PubSub),
      do:
        Phoenix.PubSub.broadcast(
          AiControl.PubSub,
          "organizations:#{organization_id}:dashboard",
          :dashboard_changed
        ),
      else: :ok
  end

  defp comparable(event) do
    event |> Map.take(Event.fields()) |> Jason.encode!() |> Jason.decode!()
  end

  defp admin_attrs?(%{target_id: id} = attrs) when not is_struct(attrs),
    do:
      Validation.uuid?(id) && Enum.all?(Map.keys(attrs), &(&1 in [:target_id, :before, :after])) &&
        Enum.all?(Map.delete(attrs, :target_id), fn {_, snapshot} -> snapshot?(snapshot) end)

  defp admin_attrs?(_), do: false

  defp snapshot?(snapshot) when is_map(snapshot) and not is_struct(snapshot),
    do:
      Enum.all?(snapshot, fn {key, value} ->
        key in @snapshot_fields && snapshot_value?(key, value)
      end)

  defp snapshot?(_), do: false
  defp snapshot_value?(:status, value), do: value in ["active", "suspended"]
  defp snapshot_value?(:role, value), do: value in ["superadmin", "admin", "user"]

  defp snapshot_value?(:permissions, value),
    do: is_list(value) && Enum.all?(value, &(&1 in Grants.permissions()))

  defp snapshot_value?(key, value) when key in [:agent_count, :model_count],
    do: Validation.duration?(value)

  defp snapshot_value?(:grants_fingerprint, value), do: Validation.checksum?(value)
  defp snapshot_value?(:grants_fingerprint_key_id, value), do: Validation.code?(value)
  defp snapshot_value?(:policy_checksum, value), do: Validation.checksum?(value)
  defp snapshot_value?(:policy_profile, value), do: value in ~w(relaxed balanced strict)
  defp snapshot_value?(:policy_source, value), do: value == "global"
  defp snapshot_value?(_, value), do: Validation.uuid?(value)
end
