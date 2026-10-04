defmodule AiControl.Approvals do
  @moduledoc "Durable, identity-bound human review. Approval never performs an effect."
  import Ecto.Query

  alias AiControl.Accounts.Scope
  alias AiControl.ApiKeys.Principal
  alias AiControl.Approvals.{Approval, Cipher}
  alias AiControl.{Audit, Knowledge, Organizations, Policies, Repo}
  alias AiControl.Organizations.{Access, Grants, Organization}
  alias AiControl.Security.Fingerprint
  alias AiControl.Workflows.{Operation, Run}

  @statuses ~w(pending approved claimed consumed rejected expired invalidated uncertain)
  @kinds ~w(tool chat delegation)
  @live ~w(pending approved claimed)
  def statuses, do: @statuses
  def now, do: Application.get_env(:ai_control, :approval_clock, &DateTime.utc_now/0).()

  def required?(policy, kind, input) do
    review = policy.settings["review"] || %{}
    review["enabled"] == true and selected?(review, kind, input)
  end

  defp selected?(review, "tool", input), do: input["tool"] in (review["tools"] || [])

  defp selected?(review, "chat", input),
    do: Grants.includes?(review["llm_models"] || [], input["model"])

  defp selected?(review, "delegation", input),
    do: Grants.includes?(review["delegation_agents"] || [], input["target_agent_id"])

  @doc "Return a new binding, an existing wait, or atomically claim exactly one resume."
  def prepare(identity, kind, input, policy, request_id, opts) do
    required = required?(policy, kind, input)
    reference = opts[:run_context]

    with {:ok, current} <- Policies.refresh_identity(identity),
         true <- kind in @kinds,
         {:ok, attrs} <- identity_attrs(current, opts[:agent_id]),
         {:ok, digest} <-
           fingerprint(attrs.organization_id, {kind, canonical(input), reference_ids(reference)}),
         {:ok, key} <- key(opts[:idempotency_key], required or not is_nil(opts[:approval_id])) do
      binding =
        struct!(
          Approval,
          Map.merge(attrs, %{
            kind: kind,
            operation: operation(kind, input),
            model: if(kind == "chat", do: input["model"]),
            target_agent_id: if(kind == "delegation", do: input["target_agent_id"]),
            run_id: reference_value(reference, :run_id),
            participant_id: reference_value(reference, :participant_id),
            operation_request_id: logical_request_id(attrs, kind, key, request_id),
            input_digest: digest.digest,
            fingerprint_key_id: digest.key_id,
            policy_version: policy.version,
            policy_checksum: policy.checksum,
            idempotency_key: key
          })
        )

      result = prepare_binding(binding, request_id, opts, required)

      charge_review_attempt(
        current,
        kind,
        policy,
        request_id,
        result,
        required or not is_nil(opts[:approval_id])
      )
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp charge_review_attempt(_, "chat", _, _, {:ok, _} = result, _), do: result
  defp charge_review_attempt(_, _, _, _, result, false), do: result

  defp charge_review_attempt(identity, _, policy, request_id, result, true) do
    case AiControl.Budgets.charge_review_request(identity, policy) do
      {:ok, :ok} ->
        result

      error ->
        finish_attempt(identity, request_id)
        error
    end
  end

  defp prepare_binding(binding, request_id, opts, required) do
    if required || opts[:approval_id] || binding.idempotency_key do
      transaction(binding.organization_id, fn ->
        prepare_locked(binding, request_id, opts, required)
      end)
    else
      {:ok, nil}
    end
  end

  defp prepare_locked(binding, request_id, opts, required) do
    record = existing_binding(binding, opts[:approval_id])

    resolve_binding(record, binding, request_id, opts, required)
  end

  defp resolve_binding(nil, binding, _, opts, required) do
    cond do
      not is_nil(opts[:approval_id]) -> {:error, :forbidden}
      required -> {:ok, binding}
      true -> {:ok, nil}
    end
  end

  defp resolve_binding(record, binding, request_id, opts, _) do
    cond do
      record.requester != binding.requester ->
        {:error, :forbidden}

      not same_binding?(record, binding) ->
        if record.status in @live, do: transition!(record, "invalidated")
        {:error, :approval_conflict}

      true ->
        resume(expire!(record), opts[:approval_id], request_id)
    end
  end

  defp existing_binding(binding, nil) do
    Repo.get_by(
      Approval,
      [
        organization_id: binding.organization_id,
        requester: binding.requester,
        kind: binding.kind,
        idempotency_key: binding.idempotency_key
      ],
      log: false
    )
  end

  defp existing_binding(binding, value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} ->
        Repo.get_by(Approval, [id: id, organization_id: binding.organization_id], log: false)

      _ ->
        Repo.rollback(:invalid_request)
    end
  end

  defp same_binding?(record, binding),
    do:
      Map.take(record, [:input_digest, :fingerprint_key_id, :idempotency_key, :kind]) ==
        Map.take(binding, [:input_digest, :fingerprint_key_id, :idempotency_key, :kind])

  defp resume(%{status: "pending"} = record, _, _), do: waiting(record)
  defp resume(%{status: "approved"} = record, nil, _), do: waiting(record)

  defp resume(%{status: "approved"} = record, _, request_id) do
    claimed =
      transition!(record, "claimed", claim_id: Ecto.UUID.generate(), claim_request_id: request_id)

    {:ok, claimed}
  end

  defp resume(%{status: "rejected"}, _, _), do: {:error, :approval_rejected}
  defp resume(%{status: "expired"}, _, _), do: {:error, :approval_expired}
  defp resume(%{status: "invalidated"}, _, _), do: {:error, :approval_conflict}
  defp resume(_, _, _), do: {:error, :approval_used}

  @doc "Called only after every mandatory guard and redaction has completed."
  def gate(nil, _identity, _payload, _policy, _opts), do: :ok

  def gate(%Approval{} = ticket, identity, payload, policy, opts) do
    sources = opts[:knowledge_sources] || []

    material = %{
      "payload" => payload,
      "sources" => sources,
      "model_digest" => opts[:model_digest]
    }

    with {:ok, digest} <- fingerprint(ticket.organization_id, material) do
      transaction(ticket.organization_id, fn ->
        gate_locked(ticket, identity, payload, policy, digest, sources)
      end)
    end
  end

  defp gate_locked(%{id: nil} = ticket, identity, payload, _policy, digest, sources),
    do: create!(ticket, identity, payload, digest, sources)

  defp gate_locked(ticket, _identity, _payload, policy, digest, _sources) do
    record = locked!(ticket.organization_id, ticket.id) |> expire!()

    cond do
      not claim?(record, ticket) ->
        {:error, :approval_used}

      record.prepared_digest != digest.digest or record.fingerprint_key_id != digest.key_id ->
        transition!(record, "invalidated")
        {:error, :approval_conflict}

      not approver_access?(record, policy) ->
        transition!(record, "invalidated")
        {:error, :forbidden}

      true ->
        update!(record, validated_policy_checksum: policy.checksum)
        :ok
    end
  end

  defp create!(ticket, identity, payload, digest, sources) do
    existing =
      Repo.get_by(
        Approval,
        [
          organization_id: ticket.organization_id,
          requester: ticket.requester,
          kind: ticket.kind,
          idempotency_key: ticket.idempotency_key
        ],
        log: false
      )

    if existing do
      resolve_created(existing, ticket, digest)
    else
      deadline = workflow_deadline(ticket)

      record = %{
        ticket
        | id: Ecto.UUID.generate(),
          prepared_digest: digest.digest,
          sources: sources,
          workflow_deadline: deadline,
          expires_at: deadline(now(), deadline)
      }

      case Cipher.encrypt(record.id, record.organization_id, payload) do
        {:ok, ciphertext, key_id} ->
          record =
            Repo.insert!(%{record | ciphertext: ciphertext, encryption_key_id: key_id},
              log: false
            )

          audit!(record, "pending", identity)
          mark_waiting!(record)
          waiting(record)

        error ->
          error
      end
    end
  end

  # Two attempts can finish preparation before either has persisted its review.
  # The second gate must verify both bindings, including its current redaction/RAG.
  defp resolve_created(existing, ticket, digest) do
    if same_binding?(existing, ticket) and existing.prepared_digest == digest.digest and
         existing.fingerprint_key_id == digest.key_id do
      resume(expire!(existing), nil, ticket.operation_request_id)
    else
      if existing.status in @live, do: transition!(existing, "invalidated")
      {:error, :approval_conflict}
    end
  end

  @doc "Must run in the same transaction as the dispatch receipt and budget charge."
  def consume!(nil, _, _), do: :ok

  def consume!(%Approval{} = ticket, identity, policy) do
    record = locked!(ticket.organization_id, ticket.id) |> expire!()

    with true <- claim?(record, ticket),
         true <- record.validated_policy_checksum == policy.checksum,
         true <- approver_access?(record, policy),
         {:ok, current_policy, _} <- Policies.snapshot_for_models(identity, record.agent_id),
         true <- current_policy.checksum == policy.checksum do
      transition!(record, "consumed", consumed_at: now(), ciphertext: nil)
      :ok
    else
      _ -> Repo.rollback(:approval_conflict)
    end
  end

  def consume_receipt!(nil, _), do: :ok

  def consume_receipt!(ticket, receipt) do
    identity =
      if receipt.actor_type == "agent",
        do: %Principal{
          organization_id: receipt.organization_id,
          agent_id: receipt.agent_id,
          api_key_id: receipt.api_key_id
        },
        else: %Scope{
          organization: %Organization{id: receipt.organization_id},
          user: %AiControl.Accounts.User{id: receipt.user_id}
        }

    with {:ok, policy, _} <- Policies.snapshot_for_models(identity, receipt.agent_id),
         true <- policy.checksum == receipt.policy_checksum do
      consume!(ticket, identity, policy)
    else
      _ -> Repo.rollback(:approval_conflict)
    end
  end

  def finish_attempt(identity, request_id) do
    with {:ok, attrs} <- identity_attrs(identity, nil) do
      for record <-
            Repo.all(
              from(a in Approval,
                where:
                  a.organization_id == ^attrs.organization_id and
                    a.claim_request_id == ^request_id and a.status == "claimed"
              ),
              log: false
            ),
          do: finish(record)
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc "A claimed operation is never made reusable, including failure before dispatch."
  def finish(nil), do: :ok
  def finish(%Approval{id: nil}), do: :ok

  def finish(ticket) do
    transaction(ticket.organization_id, fn ->
      record = locked!(ticket.organization_id, ticket.id)
      if claim?(record, ticket), do: transition!(record, "invalidated", ciphertext: nil)
      :ok
    end)
  end

  def decide(scope, id, action, revision) when action in [:approve, :reject] do
    with {:ok, current} <- Access.authorize(scope, "approvals.manage"),
         true <- Organizations.managers?(current),
         {:ok, id} <- Ecto.UUID.cast(id) do
      transaction(current.organization.id, fn -> decide_locked(current, id, action, revision) end)
    else
      _ -> {:error, :forbidden}
    end
  end

  defp decide_locked(current, id, action, revision) do
    record = locked!(current.organization.id, id) |> expire!()

    with :ok <- visible(current, record),
         true <- record.status == "pending" and record.revision == revision,
         {:ok, policy, _} <- Policies.snapshot_for_knowledge(current, "approvals.manage"),
         :ok <- source_access(current, policy, record.sources),
         {:ok, _} <- Cipher.decrypt(record) do
      attrs = [approver_id: current.user.id, decided_at: now()]

      attrs =
        if action == :approve,
          do: Keyword.put(attrs, :expires_at, deadline(now(), record.workflow_deadline)),
          else: Keyword.put(attrs, :ciphertext, nil)

      {:ok,
       transition!(
         record,
         if(action == :approve, do: "approved", else: "rejected"),
         attrs,
         current
       )}
    else
      false -> {:error, :approval_conflict}
      error -> error
    end
  end

  def manageable?(scope, record) do
    with {:ok, current} <- Access.authorize(scope, "approvals.manage"),
         true <- Organizations.managers?(current),
         :ok <- visible(current, record),
         do: true,
         else: (_ -> false)
  end

  def fetch(scope, id) do
    with {:ok, current} <- Access.authorize(scope, "approvals.read"),
         {:ok, id} <- Ecto.UUID.cast(id) do
      transaction(current.organization.id, fn -> fetch_locked(current, id) end, false)
    else
      _ -> {:error, :forbidden}
    end
  end

  defp fetch_locked(current, id) do
    record = locked!(current.organization.id, id) |> expire!()

    with :ok <- visible(current, record) do
      history =
        Repo.all(
          from(e in Audit.Event,
            where: e.organization_id == ^record.organization_id and e.target_id == ^record.id,
            order_by: [asc: e.occurred_at, asc: e.id]
          ),
          log: false
        )

      {:ok,
       %{
         approval: %{record | ciphertext: nil},
         preview: preview(current, record),
         history: history
       }}
    end
  end

  defp preview(current, %{status: status} = record) when status in ~w(pending approved) do
    with {:ok, policy, _} <- Policies.snapshot_for_knowledge(current, "approvals.read"),
         :ok <- source_access(current, policy, record.sources),
         do: Cipher.decrypt(record)
  end

  defp preview(_, _), do: {:error, :approval_used}

  def status(%Principal{} = identity, id) do
    with {:ok, current} <- Policies.refresh_identity(identity), {:ok, id} <- Ecto.UUID.cast(id) do
      transaction(current.organization_id, fn -> status_locked(current, id) end, false)
    else
      _ -> {:error, :forbidden}
    end
  end

  defp status_locked(current, id) do
    record = locked!(current.organization_id, id)

    if record.requester == requester(current),
      do: {:ok, evidence(expire!(record))},
      else: {:error, :forbidden}
  end

  def page(scope, params \\ %{}) do
    with {:ok, current} <- Access.authorize(scope, "approvals.read"),
         {:ok, number} <- page_number(params["page"]),
         true <- params["status"] in [nil, "" | @statuses],
         true <- params["kind"] in [nil, "" | @kinds],
         true <-
           valid_uuid_filter?(params["agent_id"]),
         true <-
           valid_uuid_filter?(params["run_id"]) do
      query =
        from(a in Approval,
          where: a.organization_id == ^current.organization.id,
          order_by: [desc: a.inserted_at, desc: a.id],
          limit: 51,
          offset: ^((number - 1) * 50)
        )

      query =
        if current.grants.agents == ["*"],
          do: query,
          else:
            where(
              query,
              [a],
              a.agent_id in ^current.grants.agents and
                (is_nil(a.target_agent_id) or a.target_agent_id in ^current.grants.agents)
            )

      query =
        if current.grants.models == ["*"],
          do: query,
          else: where(query, [a], is_nil(a.model) or a.model in ^current.grants.models)

      query = apply_filters(query, params)

      rows =
        Repo.all(
          select(
            query,
            [a],
            struct(a, [
              :id,
              :organization_id,
              :kind,
              :operation,
              :agent_id,
              :model,
              :status,
              :revision,
              :run_id,
              :expires_at,
              :inserted_at
            ])
          ),
          log: false
        )

      {:ok,
       %{
         approvals: Enum.take(rows, 50),
         page: number,
         next: if(length(rows) > 50, do: number + 1)
       }}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp valid_uuid_filter?(value),
    do: value in [nil, ""] or match?({:ok, _}, Ecto.UUID.cast(value))

  defp apply_filters(query, params),
    do: Enum.reduce(~w(status kind agent_id run_id), query, &apply_filter(&2, &1, params[&1]))

  defp apply_filter(query, _, value) when value in [nil, ""], do: query

  defp apply_filter(query, key, value),
    do: where(query, [a], field(a, ^String.to_existing_atom(key)) == ^value)

  def evidence(record),
    do: %{
      approval_id: record.id,
      approval_status: record.status,
      expires_at: record.expires_at,
      revision: record.revision,
      kind: record.kind,
      operation_request_id: record.operation_request_id,
      run_id: record.run_id,
      participant_id: record.participant_id
    }

  def invalidate_run!(org, run_id) do
    for record <-
          Repo.all(
            from(a in Approval,
              where: a.organization_id == ^org and a.run_id == ^run_id and a.status in ^@live
            ),
            log: false
          ) do
      transition!(record, if(record.status == "claimed", do: "uncertain", else: "invalidated"),
        ciphertext: nil
      )
    end

    :ok
  end

  def reconcile(recovery? \\ false) do
    case Repo.query("SELECT to_regclass('human_approvals')", [], log: false) do
      {:ok, %{rows: [[nil]]}} ->
        :ok

      {:ok, _} ->
        rows = Repo.all(from(a in Approval, where: a.status in ^@live), log: false)

        Enum.reduce_while(rows, :ok, fn row, :ok -> reconcile_record(row, recovery?) end)

      _ ->
        {:error, :approval_unavailable}
    end
  end

  defp reconcile_record(row, recovery?) do
    case transaction(row.organization_id, fn -> reconcile_locked(row, recovery?) end) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp reconcile_locked(row, recovery?) do
    record = locked!(row.organization_id, row.id)

    if recovery? and record.status == "claimed",
      do: transition!(record, "uncertain", ciphertext: nil),
      else: expire!(record)

    :ok
  end

  defp expire!(%{status: status} = record) when status in @live do
    run =
      if record.run_id,
        do:
          Repo.get_by(Run, [id: record.run_id, organization_id: record.organization_id],
            log: false
          )

    cond do
      DateTime.compare(now(), record.expires_at) != :lt ->
        transition!(record, "expired", ciphertext: nil)

      not is_nil(record.run_id) and (is_nil(run) or run.status != "running") ->
        transition!(record, "invalidated", ciphertext: nil)

      true ->
        record
    end
  end

  defp expire!(record), do: record

  defp visible(scope, record) do
    if scope.organization.status == :active and
         Grants.includes?(scope.grants.agents, record.agent_id) and
         (is_nil(record.target_agent_id) or
            Grants.includes?(scope.grants.agents, record.target_agent_id)) and
         (is_nil(record.model) or Grants.includes?(scope.grants.models, record.model)),
       do: :ok,
       else: {:error, :forbidden}
  end

  defp approver_access?(%{approver_id: nil}, _), do: false

  defp approver_access?(record, policy) do
    user = Repo.get(AiControl.Accounts.User, record.approver_id, log: false)

    with %{} <- user,
         {:ok, scope} <- Organizations.fetch_scope(Scope.for_user(user), record.organization_id),
         true <- manageable?(scope, record),
         :ok <- source_access(scope, policy, record.sources),
         do: true,
         else: (_ -> false)
  end

  defp source_access(_, _, []), do: :ok
  defp source_access(scope, policy, sources), do: Knowledge.recheck(scope, policy, sources)

  defp claim?(record, ticket),
    do:
      record.status == "claimed" and record.claim_id == ticket.claim_id and
        record.requester == ticket.requester

  defp waiting(record), do: {:error, {:approval_required, evidence(record)}}

  defp transition!(record, status, attrs \\ [], identity \\ nil) do
    attrs = if status in @live, do: attrs, else: Keyword.put(attrs, :ciphertext, nil)

    updated =
      update!(record, Keyword.merge([status: status, revision: record.revision + 1], attrs))

    audit!(updated, status, identity || owner(record))
    if status not in @live and status != "consumed", do: close_waiting!(updated)
    updated
  end

  defp close_waiting!(record) do
    Repo.update_all(
      from(o in Operation,
        where:
          o.organization_id == ^record.organization_id and
            o.request_id == ^record.operation_request_id and o.status == "awaiting_review"
      ),
      [set: [status: "finished"]],
      log: false
    )

    Repo.update_all(
      from(e in AiControl.Tools.Execution,
        where:
          e.organization_id == ^record.organization_id and
            e.request_id == ^record.operation_request_id and e.status == "awaiting_review"
      ),
      [set: [status: "rejected", code: "approval_" <> record.status, finished_at: now()]],
      log: false
    )
  end

  defp audit!(record, status, identity) do
    case Audit.record_approval(identity, record, status) do
      {:ok, _} -> :ok
      _ -> Repo.rollback(:audit_unavailable)
    end
  end

  defp mark_waiting!(record) do
    Repo.update_all(
      from(o in Operation,
        where:
          o.organization_id == ^record.organization_id and
            o.request_id == ^record.operation_request_id
      ),
      [set: [status: "awaiting_review"]],
      log: false
    )

    Repo.update_all(
      from(e in AiControl.Tools.Execution,
        where:
          e.organization_id == ^record.organization_id and
            e.request_id == ^record.operation_request_id and e.status == "pending"
      ),
      [set: [status: "awaiting_review"]],
      log: false
    )
  end

  defp owner(%{actor_type: "agent"} = record),
    do: %Principal{
      organization_id: record.organization_id,
      agent_id: record.agent_id,
      api_key_id: record.api_key_id
    }

  defp owner(record),
    do: %Scope{
      organization: %Organization{id: record.organization_id},
      user: %AiControl.Accounts.User{id: record.user_id}
    }

  defp requester(%Principal{} = p), do: "key:" <> p.api_key_id

  defp identity_attrs(%Principal{} = p, _),
    do:
      {:ok,
       %{
         organization_id: p.organization_id,
         agent_id: p.agent_id,
         api_key_id: p.api_key_id,
         actor_type: "agent",
         requester: requester(p)
       }}

  defp identity_attrs(%Scope{} = s, agent),
    do:
      {:ok,
       %{
         organization_id: s.organization.id,
         agent_id: agent,
         user_id: s.user.id,
         actor_type: "user",
         requester: "user:" <> s.user.id
       }}

  defp logical_request_id(_, _, nil, request_id), do: request_id

  defp logical_request_id(attrs, kind, key, _) do
    <<a::32, b::16, c::12, d::62, _::bitstring>> =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          {"approval.operation.v1", attrs.organization_id, attrs.requester, kind, key}
        )
      )

    Ecto.UUID.load!(<<a::32, b::16, 5::4, c::12, 2::2, d::62>>)
  end

  defp operation("tool", input), do: input["tool"]
  defp operation("chat", input), do: input["model"]
  defp operation("delegation", _), do: "delegation"
  defp reference_value(nil, _), do: nil
  defp reference_value(reference, field), do: Map.get(reference, field)
  defp reference_ids(nil), do: nil
  defp reference_ids(reference), do: Map.take(reference, [:run_id, :participant_id])

  defp canonical(value) when is_map(value),
    do: value |> Enum.sort() |> Enum.map(fn {k, v} -> {k, canonical(v)} end)

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp fingerprint(org, value),
    do:
      Fingerprint.content(org, :input, :erlang.term_to_binary({"approval.v1", canonical(value)}))

  defp key(nil, false), do: {:ok, nil}

  defp key(value, _) do
    case Ecto.UUID.cast(value) do
      {:ok, key} -> {:ok, key}
      _ -> {:error, :invalid_request}
    end
  end

  defp page_number(nil), do: {:ok, 1}

  defp page_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n in 1..10_000 -> {:ok, n}
      _ -> {:error, :invalid_request}
    end
  end

  defp page_number(_), do: {:error, :invalid_request}
  defp deadline(time, nil), do: DateTime.add(time, 900, :second)

  defp deadline(time, limit),
    do:
      Enum.min_by([DateTime.add(time, 900, :second), limit], &DateTime.to_unix(&1, :microsecond))

  defp workflow_deadline(%{run_id: nil}), do: nil

  defp workflow_deadline(record),
    do:
      Repo.get_by!(Run, [id: record.run_id, organization_id: record.organization_id], log: false).deadline

  defp locked!(org, id) do
    case Repo.one(
           from(a in Approval,
             where: a.id == ^id and a.organization_id == ^org,
             lock: "FOR UPDATE"
           ),
           log: false
         ) do
      nil -> Repo.rollback(:forbidden)
      record -> record
    end
  end

  defp update!(record, attrs),
    do: record |> Ecto.Changeset.change(attrs) |> Repo.update!(log: false)

  defp transaction(org, fun, notify? \\ true) do
    result =
      Repo.transaction(
        fn ->
          Repo.one!(from(o in Organization, where: o.id == ^org, lock: "FOR UPDATE"), log: false)
          fun.()
        end,
        log: false
      )

    case result do
      {:ok, value} ->
        if notify?, do: notify(org)
        value

      error ->
        error
    end
  rescue
    _ -> {:error, :approval_unavailable}
  end

  def notify(org) do
    if not Repo.in_transaction?() and Process.whereis(AiControl.PubSub) do
      Audit.notify(org)

      Phoenix.PubSub.broadcast(
        AiControl.PubSub,
        "organizations:#{org}:approvals",
        :approvals_changed
      )
    end

    :ok
  end
end
