defmodule AiControl.Gateway do
  @moduledoc "Verified identity → one policy → audited input → pinned backend → audited output."
  alias AiControl.Accounts.Scope
  alias AiControl.ApiKeys.Principal
  alias AiControl.{Audit, Budgets, Policies}
  alias AiControl.Budgets.Usage
  alias AiControl.Gateway.{Config, Limiter, Models, Request, Response, Slots, Stages, ToolSchemas}
  alias AiControl.Gateway.Measurements
  alias AiControl.Security.SecurityContext

  def chat(identity, params, opts \\ []) do
    execute(identity, Keyword.put(opts, :operation, "chat"), fn current, request_id, opts ->
      with :ok <- input_size(params),
           {:ok, params} <- Request.validate(params),
           {:ok, policy, current} <- Policies.snapshot_for_models(current, opts[:agent_id]) do
        {result, stage} = process_chat(current, params, policy, request_id, opts)
        {result, policy, stage}
      else
        error -> {error, nil, :input}
      end
    end)
  end

  defp process_chat(current, params, policy, request_id, opts) do
    with :ok <- Policies.model_access(current, policy, opts[:agent_id], params["model"]),
         {:ok, receipt} <-
           measure(
             :budget_admission,
             fn ->
               Budgets.admit(current, opts[:agent_id], params["model"], policy, request_id)
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
    with {:ok, safe} <- Stages.evaluate(params, current, policy, request_id, :input, opts),
         {:ok, safe} <- Request.validate(safe),
         {:ok, contract} <- ToolSchemas.prepare(safe),
         :ok <- authorize_again(current, policy, opts[:agent_id], params["model"]) do
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

  defp filter_output(response, current, policy, request_id, safe, contract, opts) do
    with {:ok, response} <- Response.normalize(response, safe["model"], request_id),
         :ok <- Response.validate(response, contract) do
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
      )
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
         {:ok, receipt} <- Budgets.dispatch(receipt),
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
    if Budgets.hard_limit?(policy) do
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
      Map.merge(attrs, %{
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
