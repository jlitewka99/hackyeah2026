defmodule AiControl.Tools.Executor do
  @moduledoc "Public firewall orchestration; only filtered results leave this module."
  alias AiControl.{Audit, Gateway, Repo, Tools}
  alias AiControl.Gateway.{Limiter, Slots, Stages}
  alias AiControl.Tools.{Config, Content, Execution, Executions, Sandbox, ToolRequest}

  def execute(%AiControl.ApiKeys.Principal{} = identity, params, opts) do
    request_id = opts[:request_id] || Ecto.UUID.generate()
    started = System.monotonic_time()
    perform(identity, params, opts, request_id, started)
  end

  def execute(_, _, _), do: {:error, :forbidden}

  defp perform(identity, params, opts, request_id, started) do
    with :ok <- ingress(identity, opts),
         {:ok, key} <- Ecto.UUID.cast(opts[:idempotency_key]),
         {:ok, prepared} <- Tools.prepare(identity, params),
         request = %{prepared | request_id: request_id},
         {:ok, server} <- server(request.organization_id),
         {:ok, resources} <- Sandbox.preflight(server, request),
         {:ok, receipt} <- Executions.claim(request, resources.workflow_id, key) do
      {result, stage} = process(request, server, resources, receipt)
      finish(receipt, request, result, stage, started)
    else
      :error -> reject(identity, request_id, {:error, :invalid_request}, started)
      error -> reject(identity, request_id, error, started)
    end
  rescue
    _ -> reject(identity, request_id, {:error, :tool_unavailable}, started)
  catch
    :exit, _ -> reject(identity, request_id, {:error, :tool_unavailable}, started)
  end

  defp process(request, server, resources, receipt) do
    identity = ToolRequest.principal(request)
    input = %{"tool" => request.tool, "arguments" => request.arguments}

    opts = [
      content_adapter: Content,
      tool_request: request,
      resource_grant: resources.grant,
      resource_files: resources.files
    ]

    with {:ok, safe} <-
           Stages.evaluate(input, identity, request.policy, request.request_id, :input, opts),
         updated = %{request | arguments: safe["arguments"]},
         :ok <- Tools.authorize(updated),
         {:ok, _} <- Sandbox.preflight(server, updated) do
      owner = self()
      deadline = System.monotonic_time(:millisecond) + Config.timeout()

      result = dispatch(server, updated, receipt, owner, deadline)

      case result do
        {:ok, output} ->
          {filter_output(output, request, identity, opts, safe), :output}

        error ->
          {normalize_timeout(error), :dispatch}
      end
    else
      error -> {error, :input}
    end
  end

  defp dispatch(server, request, receipt, owner, deadline) do
    Gateway.measure(:tool_execution, fn ->
      Slots.run(:tool, Config.timeout(), fn ->
        Sandbox.run_prepared(server, request, receipt, owner, deadline)
      end)
    end)
  end

  defp filter_output(output, request, identity, opts, safe) do
    with :ok <- Content.validate_result(request.tool, output) do
      Stages.evaluate(
        output,
        identity,
        request.policy,
        request.request_id,
        :output,
        Keyword.put(opts, :semantic_prompt, Jason.encode!(safe))
      )
    end
  end

  defp finish(receipt, request, result, stage, started) do
    current = Repo.get!(Execution, receipt.id, log: false)
    code = code(result)
    status = status(current, result, stage, code)

    case Executions.finish(receipt, request, status, code, duration(started)) do
      {:ok, _} ->
        telemetry(status, duration(started))

        case result do
          {:ok, safe} ->
            {:ok,
             %{
               request_id: request.request_id,
               execution_id: receipt.id,
               tool: request.tool,
               result: safe
             }}

          error ->
            error
        end

      _ ->
        {:error, :audit_unavailable}
    end
  end

  defp status(%{status: "pending"}, _, _, _), do: "rejected"
  defp status(_, {:ok, _}, _, _), do: "completed"

  defp status(_, _, _, code) when code in ~w(tool_timeout tool_cancelled tool_unavailable),
    do: "uncertain"

  defp status(_, _, :output, code)
       when code in ~w(policy_blocked redaction_unavailable guard_unavailable capacity_exceeded audit_unavailable),
       do: "output_blocked"

  defp status(_, _, _, _), do: "failed"

  defp reject(identity, id, error, started) do
    case Audit.record_tool(
           identity,
           id,
           "tool.rejected",
           code(error),
           duration(started),
           nil,
           nil
         ) do
      {:ok, _} ->
        telemetry("rejected", duration(started))
        error

      _ ->
        {:error, :audit_unavailable}
    end
  end

  defp code({:ok, _}), do: "completed"
  defp code({:error, {code, _}}), do: Atom.to_string(code)
  defp code({:error, code}), do: Atom.to_string(code)
  defp normalize_timeout({:error, :upstream_timeout}), do: {:error, :tool_timeout}
  defp normalize_timeout({:error, :upstream_unavailable}), do: {:error, :tool_unavailable}
  defp normalize_timeout(error), do: error

  defp ingress(identity, opts),
    do: if(opts[:ingress_checked?], do: :ok, else: Limiter.check(identity))

  defp server(org) do
    case Registry.lookup(AiControl.Tools.Registry, org) do
      [{pid, _}] -> {:ok, pid}
      _ -> {:error, :tool_not_allowed}
    end
  end

  defp duration(started),
    do: System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)

  defp telemetry(status, duration),
    do:
      :telemetry.execute([:ai_control, :tools, :execution], %{duration_us: duration}, %{
        status: status
      })
end
