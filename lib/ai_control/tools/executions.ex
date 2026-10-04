defmodule AiControl.Tools.Executions do
  @moduledoc "Atomic identity-bound claims and dispatch accounting; effects are never retried."
  import Ecto.Query

  alias AiControl.{Audit, Budgets, Repo, Tools}
  alias AiControl.Organizations.Organization
  alias AiControl.Policy.Snapshot
  alias AiControl.Security.Fingerprint
  alias AiControl.Tools.{Execution, ToolRequest}

  def claim(request, workflow, key) do
    with {:ok, key} <- Ecto.UUID.cast(key),
         {:ok, fingerprint} <- fingerprint(request) do
      transaction(fn -> claim!(request, workflow, key, fingerprint) end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp claim!(request, workflow, key, fingerprint) do
    lock_org(request.organization_id)

    existing =
      Repo.get_by(
        Execution,
        [
          organization_id: request.organization_id,
          agent_id: request.agent_id,
          idempotency_key: key
        ],
        log: false
      )

    if existing do
      code =
        if existing.fingerprint_digest == fingerprint.digest &&
             existing.fingerprint_key_id == fingerprint.key_id,
           do: :tool_execution_exists,
           else: :idempotency_conflict

      Repo.rollback({code, %{execution_id: existing.id, execution_status: existing.status}})
    else
      Repo.insert!(
        %Execution{
          organization_id: request.organization_id,
          agent_id: request.agent_id,
          api_key_id: request.api_key_id,
          request_id: request.request_id,
          workflow_id: workflow,
          run_id: if(request.run_context, do: request.run_context.run_id),
          participant_id: if(request.run_context, do: request.run_context.participant_id),
          idempotency_key: key,
          tool: request.tool,
          fingerprint_digest: fingerprint.digest,
          fingerprint_key_id: fingerprint.key_id,
          policy_version: request.policy.version,
          policy_checksum: request.policy.checksum,
          policy_settings: request.policy.settings
        },
        log: false
      )
    end
  end

  def dispatch(receipt, request), do: transaction(fn -> dispatch!(receipt, request) end)

  defp dispatch!(receipt, request) do
    lock_org(receipt.organization_id)
    # Budgets locks the workflow before the execution receipt.
    with true <- bound?(receipt, request),
         :ok <- Tools.authorize(request),
         {:ok, _} <-
           Budgets.consume_tool_call(
             ToolRequest.principal(request),
             nil,
             request.policy,
             receipt.workflow_id,
             receipt.id,
             request.run_context
           ) do
      current = locked(receipt)
      if current.status != "pending", do: Repo.rollback(:tool_cancelled)

      updated =
        Repo.update!(
          Ecto.Changeset.change(current,
            status: "dispatching",
            charged: true,
            dispatched_at: DateTime.utc_now()
          ),
          log: false
        )

      audit!(updated, request, "tool.dispatching", "dispatching", 0)
      updated
    else
      false -> Repo.rollback(:forbidden)
      {:error, code} when code in [:workflow_limit_exceeded, :workflow_terminal] -> {:error, code}
      {:error, code} -> Repo.rollback(code)
    end
  end

  def finish(receipt, request, status, code, duration) do
    transaction(fn ->
      lock_org(receipt.organization_id)
      current = locked(receipt)
      if !bound?(current, request), do: Repo.rollback(:forbidden)

      allowed =
        if current.status == "pending",
          do: ["rejected"],
          else: ~w(completed output_blocked failed uncertain)

      if current.status not in ~w(pending dispatching) || status not in allowed,
        do: Repo.rollback(:tool_cancelled)

      updated =
        Repo.update!(
          Ecto.Changeset.change(current,
            status: status,
            code: code,
            finished_at: DateTime.utc_now()
          ),
          log: false
        )

      audit!(updated, request, "tool." <> status, code, duration)
      updated
    end)
  end

  def evidence(receipt),
    do: %{
      execution_id: receipt.id,
      workflow_id: receipt.workflow_id,
      execution_status: receipt.status,
      tool: receipt.tool,
      charged: receipt.charged
    }

  def recover_request(org, request_id) do
    transaction(fn ->
      lock_org(org)

      case Repo.get_by(Execution, [organization_id: org, request_id: request_id], log: false) do
        nil -> :ok
        receipt -> recover!(receipt)
      end

      :ok
    end)
  end

  def recover do
    transaction(fn ->
      receipts =
        Repo.all(from(e in Execution, where: e.status in ~w(pending dispatching)), log: false)

      Enum.each(receipts, &recover!/1)
      :ok
    end)
  end

  defp recover!(receipt) do
    lock_org(receipt.organization_id)
    current = locked(receipt)

    if current.status in ~w(pending dispatching) do
      status = if current.status == "pending", do: "rejected", else: "uncertain"

      {:ok, policy} =
        Snapshot.new(%{
          version: current.policy_version,
          checksum: current.policy_checksum,
          settings: current.policy_settings,
          rules: policy_rules(current.policy_settings)
        })

      request = %ToolRequest{
        request_id: current.request_id,
        organization_id: current.organization_id,
        agent_id: current.agent_id,
        api_key_id: current.api_key_id,
        tool: current.tool,
        arguments: %{},
        policy: policy
      }

      updated =
        Repo.update!(
          Ecto.Changeset.change(current,
            status: status,
            code: "tool_interrupted",
            finished_at: DateTime.utc_now()
          ),
          log: false
        )

      audit!(updated, request, "tool." <> status, "tool_interrupted", 0)
    end
  end

  defp bound?(receipt, request) do
    receipt.organization_id == request.organization_id && receipt.agent_id == request.agent_id &&
      receipt.api_key_id == request.api_key_id && receipt.request_id == request.request_id &&
      receipt.tool == request.tool && receipt.policy_checksum == request.policy.checksum &&
      receipt.policy_version == request.policy.version
  end

  defp policy_rules(settings) do
    Map.new(settings["rules"], fn {category, rule} ->
      {category,
       %{
         id: rule["id"],
         action: %{"allow" => :allow, "block" => :block, "redact" => :redact}[rule["action"]],
         threshold: Map.get(rule, "threshold", 0)
       }}
    end)
  end

  defp fingerprint(request) do
    payload =
      canonical(
        Map.reject(
          %{
            "tool" => request.tool,
            "arguments" => request.arguments,
            "agent" => request.agent_id,
            "run" => if(request.run_context, do: request.run_context.run_id),
            "participant" => if(request.run_context, do: request.run_context.participant_id)
          },
          fn {key, value} -> key in ~w(run participant) && is_nil(value) end
        )
      )

    Fingerprint.content(
      request.organization_id,
      :input,
      :erlang.term_to_binary({"tool.execution.v1", payload})
    )
  end

  defp canonical(value) when is_map(value),
    do: value |> Enum.sort() |> Enum.map(fn {k, v} -> {k, canonical(v)} end)

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp locked(receipt),
    do:
      Repo.one!(
        from(e in Execution,
          where: e.id == ^receipt.id and e.organization_id == ^receipt.organization_id,
          lock: "FOR UPDATE"
        ), log: false)

  defp lock_org(org),
    do: Repo.one!(from(o in Organization, where: o.id == ^org, lock: "FOR UPDATE"), log: false)

  defp audit!(receipt, request, type, code, duration) do
    case Audit.record_tool(
           ToolRequest.principal(request),
           request.request_id,
           type,
           code,
           duration,
           request.policy,
           evidence(receipt)
         ) do
      {:ok, _} -> :ok
      _ -> Repo.rollback(:audit_unavailable)
    end
  end

  defp transaction(fun) do
    result = Repo.transaction(fun, log: false)

    case result do
      {:ok, %Execution{organization_id: id}} -> if !Repo.in_transaction?(), do: Audit.notify(id)
      _ -> :ok
    end

    case result do
      {:ok, {:error, _} = error} -> error
      _ -> result
    end
  rescue
    _ -> {:error, :tool_unavailable}
  catch
    :exit, _ -> {:error, :tool_unavailable}
  end
end
