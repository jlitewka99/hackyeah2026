defmodule AiControl.Audit do
  @moduledoc "Synchronous, tenant-scoped audit writes with an explicit content-free serializer."
  import Ecto.Query

  alias AiControl.Audit.Event
  alias AiControl.Organizations
  alias AiControl.Organizations.{Access, Grants}
  alias AiControl.Repo

  alias AiControl.Security.{
    Decision,
    Fingerprint,
    SecurityAssessment,
    SecurityContext,
    Validation
  }

  @admin_events ~w(organization.created organization.status_changed member.access_changed member.removed superadmin.transferred invitation.issued invitation.revoked invitation.accepted invitation.delivery_failed)
  @snapshot_fields ~w(status role permissions agent_count model_count grants_fingerprint grants_fingerprint_key_id user_id previous_superadmin_id next_superadmin_id membership_id invitation_id)a

  def record_decision(context, assessment, decision) do
    if valid_decision?(context, assessment, decision) do
      event = %Event{
        id: assessment.id,
        organization_id: context.organization_id,
        actor_type: context.actor_type,
        user_id: context.user_id,
        agent_id: context.agent_id,
        api_key_id: context.api_key_id,
        request_id: context.request_id,
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
        data: assessment_data(assessment, decision)
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
       Repo.all(
         from(e in Event,
           where: e.organization_id == ^current.organization.id,
           order_by: [desc: e.occurred_at, desc: e.id],
           limit: ^limit,
           offset: ^offset
         ),
         log: false
       )}
    else
      {:error, _} -> {:error, :forbidden}
      _ -> {:error, :invalid_audit_data}
    end
  end

  def get_event(scope, id) do
    with {:ok, current} <- Access.authorize(scope, "events.read"),
         {:ok, id} <- Ecto.UUID.cast(id),
         %Event{} = event <-
           Repo.get_by(Event, [id: id, organization_id: current.organization.id], log: false) do
      {:ok, event}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      _ -> {:error, :not_found}
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
          Map.take(result, [:guard, :status, :signals, :duration_us, :error_code])
        end),
      detections:
        Enum.map(
          assessment.detections,
          &Map.take(&1, [:guard, :category, :rule_id, :confidence, :location])
        ),
      failed_guards: assessment.failed_guards,
      redactions: decision.redactions,
      policy_evidence: %{
        required_guards: decision.policy.required_guards,
        rules:
          Map.new(decision.policy.rules, fn {category, rule} ->
            {category,
             %{id: rule.id, action: rule.action, threshold: Map.get(rule, :threshold, 0)}}
          end)
      }
    }
  end

  defp with_fingerprint(event, nil), do: event

  defp with_fingerprint(event, fingerprint),
    do: %{event | fingerprint_digest: fingerprint.digest, fingerprint_key_id: fingerprint.key_id}

  defp persist(event) do
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
  defp snapshot_value?(_, value), do: Validation.uuid?(value)
end
