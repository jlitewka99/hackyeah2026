defmodule AiControl.Gateway do
  @moduledoc "Verified identity → one policy → audited input → pinned backend → audited output."
  alias AiControl.Accounts.Scope
  alias AiControl.ApiKeys.Principal
  alias AiControl.{Approvals, Audit, Budgets, Policies, Workflows}
  alias AiControl.Budgets.Usage
  alias AiControl.Gateway.{Config, Limiter, Models, Request, Response, Slots, Stages, ToolSchemas}
  alias AiControl.Gateway.Measurements
  alias AiControl.Security.SecurityContext

  def chat(identity, params, opts \\ []) do
    execute(identity, Keyword.put(opts, :operation, "chat"), fn current, request_id, opts ->
      with :ok <- input_size(params),
           {:ok, params} <- Request.validate(params),
           :ok <- non_streaming(params),
           {:ok, policy, current} <- Policies.snapshot_for_models(current, opts[:agent_id]),
           {:ok, context} <- Workflows.resolve(current, policy, opts[:run_context]),
           {:ok, ticket} <- Approvals.prepare(current, "chat", params, policy, request_id, opts),
           operation_id = operation_request_id(ticket, request_id),
           {:ok, context} <- Workflows.admit(context, policy, "chat", params, operation_id) do
        workflow_chat(
          context,
          current,
          params,
          policy,
          request_id,
          Keyword.put(opts, :approval_ticket, ticket)
        )
      else
        error -> {error, nil, :input}
      end
    end)
  end

  defp operation_request_id(nil, request_id), do: request_id
  defp operation_request_id(ticket, _), do: ticket.operation_request_id

  defp workflow_chat(context, current, params, policy, request_id, opts) do
    outcome =
      Workflows.run(context, fn ->
        process_chat(
          current,
          params,
          policy,
          request_id,
          Keyword.put(opts, :run_context, context)
        )
      end)

    workflow_outcome(outcome, policy)
  end

  defp workflow_outcome({result, stage}, policy) when stage in [:input, :output],
    do: {result, policy, stage}

  defp workflow_outcome(error, policy), do: {error, policy, :input}

  def start_stream(identity, params, opts \\ []),
    do: AiControl.Gateway.Stream.start(identity, params, opts)

  @doc false
  def prepare_stream(identity, params, opts) do
    with {:ok, current} <- Policies.refresh_identity(identity),
         :ok <- ingress(current, opts),
         :ok <- input_size(params),
         {:ok, params} <- Request.validate(params),
         true <- params["stream"],
         {:ok, policy, current} <- Policies.snapshot_for_models(current, opts[:agent_id]),
         {:ok, context} <- Workflows.resolve(current, policy, opts[:run_context]),
         {:ok, ticket} <-
           Approvals.prepare(current, "chat", params, policy, opts[:request_id], opts),
         operation_id = if(ticket, do: ticket.operation_request_id, else: opts[:request_id]),
         {:ok, context} <- Workflows.admit(context, policy, "chat", params, operation_id),
         :ok <- opts[:stream_context].(current, policy, context) do
      prepare_stream_request(
        current,
        params,
        policy,
        opts |> Keyword.put(:run_context, context) |> Keyword.put(:approval_ticket, ticket)
      )
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp prepare_stream_request(current, params, policy, opts) do
    request_id = opts[:request_id]
    config = Keyword.merge(Config.get(), Keyword.take(opts, [:measurements]))
    provider = config[:provider]

    with :ok <- Policies.model_access(current, policy, opts[:agent_id], params["model"]),
         {:ok, receipt} <-
           measure(
             :budget_admission,
             fn ->
               opts[:stream_admit].(current, params["model"], policy)
             end,
             opts
           ) do
      with {:ok, augmented, sources} <-
             AiControl.Knowledge.augment(current, params, policy, request_id, opts),
           :ok <- input_size(augmented),
           {:ok, safe} <- Stages.evaluate(augmented, current, policy, request_id, :input, opts),
           {:ok, safe} <- Request.validate(safe),
           {:ok, contract} <- ToolSchemas.prepare(safe),
           true <- Code.ensure_loaded?(provider) && function_exported?(provider, :chat_stream, 2),
           {:ok, models} <- provider.models(config),
           {:ok, digest} <- Models.digest(safe["model"]),
           :ok <- pinned(models, safe["model"], digest),
           safe = review_defaults(safe, opts),
           :ok <-
             Approvals.gate(opts[:approval_ticket], current, safe, policy,
               knowledge_sources: sources,
               model_digest: digest
             ),
           {:ok, safe, receipt} <- prepare_budget(safe, receipt, policy, provider, config),
           :ok <- authorize_again(current, policy, opts[:agent_id], safe["model"]),
           :ok <- recheck_knowledge(current, policy, knowledge_sources: sources) do
        {:ok,
         %{
           identity: current,
           params: safe,
           policy: policy,
           receipt: receipt,
           contract: contract,
           config: config,
           opts: Keyword.put(opts, :knowledge_sources, sources)
         }}
      else
        false -> {:error, :stream_unavailable}
        error -> error
      end
    end
  end

  @doc false
  def generate_stream(prepared, session) do
    %{params: params, config: config, opts: opts} = prepared

    on_usage = fn usage -> GenServer.call(session, {:usage, usage}, :infinity) end

    config =
      Keyword.merge(config,
        on_stream_usage: on_usage,
        on_stream_chunk: fn bytes -> GenServer.call(session, {:received, bytes}) end
      )

    result =
      measure(
        :upstream,
        fn ->
          Slots.run(:llm, Config.get(:llm_timeout), fn ->
            stream_provider(prepared, config, on_usage)
          end)
        end,
        opts
      )

    with {:ok, response} <- result,
         {:ok, safe} <-
           filter_output(
             response,
             prepared.identity,
             prepared.policy,
             opts[:request_id],
             params,
             prepared.contract,
             opts
           ),
         :ok <- response_size(safe),
         :ok <-
           authorize_again(prepared.identity, prepared.policy, opts[:agent_id], params["model"]),
         :ok <- Workflows.check(opts[:run_context]),
         do: {:ok, safe}
  end

  defp stream_provider(prepared, config, on_usage) do
    with :ok <-
           authorize_again(
             prepared.identity,
             prepared.policy,
             prepared.opts[:agent_id],
             prepared.params["model"]
           ),
         :ok <- recheck_knowledge(prepared.identity, prepared.policy, prepared.opts),
         {:ok, _} <- Budgets.dispatch(prepared.receipt, prepared.opts[:approval_ticket]),
         {:ok, response} <- config[:provider].chat_stream(prepared.params, config),
         {:ok, usage} <- response_usage(response),
         :ok <- on_usage.(usage),
         do: {:ok, response}
  end

  defp non_streaming(%{"stream" => false}), do: :ok
  defp non_streaming(_), do: {:error, :invalid_request}

  defp response_size(response),
    do:
      if(byte_size(Jason.encode!(response)) <= Config.get(:response_bytes),
        do: :ok,
        else: {:error, :response_too_large}
      )

  defp process_chat(current, params, policy, request_id, opts) do
    with :ok <- Policies.model_access(current, policy, opts[:agent_id], params["model"]),
         {:ok, receipt} <-
           measure(
             :budget_admission,
             fn ->
               Budgets.admit(
                 current,
                 opts[:agent_id],
                 params["model"],
                 policy,
                 request_id,
                 DateTime.utc_now(),
                 opts[:run_context]
               )
             end,
             opts
           ) do
      {result, stage} =
        try do
          run_chat(current, params, policy, request_id, opts, receipt)
        after
          Budgets.abandon(receipt)
        end

      {{:accounted, result, receipt}, stage}
    else
      error -> {error, :input}
    end
  end

  defp run_chat(current, params, policy, request_id, opts, receipt) do
    with {:ok, augmented, sources} <-
           AiControl.Knowledge.augment(current, params, policy, request_id, opts),
         :ok <- input_size(augmented),
         {:ok, safe} <- Stages.evaluate(augmented, current, policy, request_id, :input, opts),
         {:ok, safe} <- Request.validate(safe),
         {:ok, contract} <- ToolSchemas.prepare(safe),
         safe = review_defaults(safe, opts),
         {:ok, digest} <- Models.digest(safe["model"]),
         :ok <-
           Approvals.gate(opts[:approval_ticket], current, safe, policy,
             knowledge_sources: sources,
             model_digest: digest
           ),
         :ok <- authorize_again(current, policy, opts[:agent_id], params["model"]) do
      opts = Keyword.put(opts, :knowledge_sources, sources)

      case generate(safe, receipt, current, policy, opts) do
        {:ok, response} ->
          {filter_output(response, current, policy, request_id, safe, contract, opts), :output}

        error ->
          {error, :output}
      end
    else
      error -> {error, :input}
    end
  end

  defp review_defaults(params, opts) do
    if opts[:approval_ticket] do
      config = Config.get()
      params = Map.put_new(params, "max_tokens", config[:default_max_tokens])

      params =
        if config[:provider] == AiControl.Gateway.Ollama && config[:ollama_reasoning_effort],
          do: Map.put(params, "reasoning_effort", config[:ollama_reasoning_effort]),
          else: params

      if params["stream"],
        do: Map.put(params, "stream_options", %{"include_usage" => true}),
        else: params
    else
      params
    end
  end

  defp filter_output(response, current, policy, request_id, safe, contract, opts) do
    with {:ok, response} <- Response.normalize(response, safe["model"], request_id),
         :ok <- Response.validate(response, contract),
         {:ok, checked} <-
           Stages.evaluate(
             response,
             current,
             policy,
             request_id,
             :output,
             Keyword.merge(opts,
               tool_contract: contract,
               semantic_prompt: Jason.encode!(safe["messages"])
             )
           ),
         :ok <- authorize_again(current, policy, opts[:agent_id], safe["model"]),
         :ok <- recheck_knowledge(current, policy, opts) do
      {:ok, checked}
    end
  end

  def models(identity, opts \\ []) do
    execute(identity, Keyword.put(opts, :operation, "models"), fn current, _, _ ->
      case Policies.snapshot_for_models(current, opts[:agent_id]) do
        {:ok, policy, current} ->
          models =
            Models.all()
            |> Enum.filter(&(Policies.model_access(current, policy, opts[:agent_id], &1) == :ok))

          data =
            Enum.map(
              models,
              &%{"id" => &1, "object" => "model", "created" => 0, "owned_by" => "operator"}
            )

          {{:ok, %{"object" => "list", "data" => data}}, policy, :input}

        error ->
          {error, nil, :input}
      end
    end)
  end

  defp execute(identity, opts, callback) do
    opts = Keyword.put_new(opts, :request_id, Ecto.UUID.generate())

    Measurements.run(fn pid ->
      execute_measured(identity, Keyword.put(opts, :measurements, pid), callback)
    end)
  end

  defp execute_measured(identity, opts, callback) do
    request_id = opts[:request_id] || Ecto.UUID.generate()
    started = System.monotonic_time()

    case Policies.refresh_identity(identity) do
      {:ok, current} ->
        {result, policy, stage} =
          case ingress(current, opts) do
            :ok -> callback.(current, request_id, opts)
            error -> {error, nil, :input}
          end

        finish(current, request_id, result, policy, started, stage, opts)

      {:error, :forbidden} = error ->
        # These are trusted adapters whose previously verified access was revoked.
        case identity do
          %Principal{} -> finish(identity, request_id, error, nil, started, :input, opts)
          %Scope{} -> finish(identity, request_id, error, nil, started, :input, opts)
          _ -> error
        end
    end
  rescue
    _ -> {:error, :policy_unavailable}
  catch
    :exit, _ -> {:error, :upstream_unavailable}
  after
    Approvals.finish_attempt(identity, opts[:request_id])
  end

  defp finish(identity, request_id, result, policy, started, stage, opts) do
    {result, evidence} =
      case result do
        {:accounted, outcome, receipt} -> {outcome, Budgets.evidence(receipt)}
        outcome -> {outcome, nil}
      end

    code =
      case result do
        {:ok, _} -> "completed"
        {:error, {code, _}} -> Atom.to_string(code)
        {:error, code} -> Atom.to_string(code)
      end

    duration = duration(started)
    Measurements.record(opts[:measurements], "request", duration)

    observation = %{
      operation: opts[:operation],
      timings: Measurements.snapshot(opts[:measurements])
    }

    :telemetry.execute([:ai_control, :gateway, :request], %{duration_us: duration}, %{
      code: code,
      stage: stage
    })

    case Audit.record_gateway(
           identity,
           request_id,
           code,
           duration,
           policy,
           stage,
           evidence,
           observation
         ) do
      {:ok, _} -> result
      _ -> {:error, :audit_unavailable}
    end
  end

  defp ingress(identity, opts) do
    if opts[:ingress_checked?] == true, do: :ok, else: Limiter.check(identity)
  end

  defp authorize_again(identity, policy, agent, model) do
    with {:ok, current} <- Policies.refresh_identity(identity),
         :ok <- Policies.model_access(current, policy, agent, model) do
      identity_access(current, agent, model)
    end
  end

  defp identity_access(%Scope{} = scope, agent, model) do
    with {:ok, _} <-
           AiControl.Organizations.Access.authorize(scope, "ai.use", %{agent: agent, model: model}),
         do: :ok
  end

  defp identity_access(%Principal{}, _, _), do: :ok

  defp generate(params, receipt, identity, policy, opts) do
    measure(
      :generation,
      fn ->
        Slots.run(:llm, Config.get(:llm_timeout), fn ->
          provider_chat(params, receipt, identity, policy, opts)
        end)
      end,
      opts
    )
  end

  defp provider_chat(params, receipt, identity, policy, opts) do
    config = Keyword.merge(Config.get(), Keyword.take(opts, [:measurements]))
    provider = config[:provider]

    with {:ok, models} <- provider.models(config),
         {:ok, digest} <- Models.digest(params["model"]),
         :ok <- pinned(models, params["model"], digest),
         {:ok, params, receipt} <- prepare_budget(params, receipt, policy, provider, config),
         :ok <- authorize_again(identity, policy, opts[:agent_id], params["model"]),
         :ok <- recheck_knowledge(identity, policy, opts),
         {:ok, receipt} <- Budgets.dispatch(receipt, opts[:approval_ticket]),
         {:ok, response} <-
           measure(
             :upstream,
             fn ->
               provider.chat(params, Keyword.put(config, :budget_reservation_id, receipt.id))
             end,
             opts
           ),
         {:ok, usage} <- response_usage(response),
         {:ok, _} <- measure(:budget_settlement, fn -> Budgets.settle(receipt, usage) end, opts) do
      {:ok, response}
    end
  end

  defp prepare_budget(params, receipt, policy, provider, config) do
    if Budgets.hard_limit?(policy) || receipt.run_id do
      params = Map.put_new(params, "max_tokens", config[:default_max_tokens])
      tokenizer = config[:tokenizer]

      measure(
        :budget_reservation,
        fn ->
          reserve_tokens(params, receipt, provider, tokenizer, config)
        end,
        config
      )
    else
      {:ok, params, receipt}
    end
  end

  defp recheck_knowledge(identity, policy, opts) do
    case opts[:knowledge_sources] do
      sources when sources in [nil, []] -> :ok
      sources -> AiControl.Knowledge.recheck(identity, policy, sources)
    end
  end

  defp reserve_tokens(params, receipt, provider, tokenizer, config) do
    with {:ok, prompt} <- provider.prepare(params, config),
         {:ok, input} <- tokenizer.count(params["model"], prompt, config),
         {:ok, receipt} <- Budgets.reserve(receipt, input, params["max_tokens"]) do
      {:ok, params, receipt}
    end
  end

  defp response_usage(response) do
    case Usage.normalize(response["usage"]) do
      {:ok, usage} -> {:ok, usage}
      _ -> {:error, :upstream_invalid_response}
    end
  end

  def pinned(models, name, digest) do
    case Map.get(models, name) do
      nil -> {:error, :model_unavailable}
      ^digest -> :ok
      _ -> {:error, :model_digest_mismatch}
    end
  end

  defp input_size(params) do
    if byte_size(Jason.encode!(params)) <= Config.get(:input_bytes),
      do: :ok,
      else: {:error, :input_too_large}
  end

  def context(identity, policy, request_id, stage) do
    attrs =
      case identity do
        %Principal{} ->
          %{
            actor_type: :agent,
            organization_id: identity.organization_id,
            agent_id: identity.agent_id,
            api_key_id: identity.api_key_id
          }

        %Scope{} ->
          %{
            actor_type: :user,
            organization_id: identity.organization.id,
            user_id: identity.user.id
          }
      end

    SecurityContext.new(
      Map.merge(Map.merge(attrs, Workflows.audit_reference(identity, request_id)), %{
        request_id: request_id,
        stage: stage,
        policy_version: policy.version,
        policy_checksum: policy.checksum
      })
    )
  end

  def measure(stage, callback, opts \\ []) do
    started = System.monotonic_time()

    try do
      callback.()
    after
      elapsed = duration(started)

      key =
        if is_tuple(stage), do: stage |> Tuple.to_list() |> Enum.join("."), else: to_string(stage)

      Measurements.record(opts[:measurements], key, elapsed)

      :telemetry.execute([:ai_control, :gateway, :stage], %{duration_us: duration(started)}, %{
        stage: if(is_tuple(stage), do: :guard, else: stage)
      })
    end
  end

  defp duration(started),
    do: System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
end
