defmodule AiControl.Gateway do
  @moduledoc "Verified identity → one policy → audited input → pinned backend → audited output."
  alias AiControl.Accounts.Scope
  alias AiControl.ApiKeys.Principal
  alias AiControl.{Audit, Policies}
  alias AiControl.Gateway.{Config, Limiter, Models, Request, Response, Slots, Stages}
  alias AiControl.Security.SecurityContext

  def chat(identity, params, opts \\ []) do
    execute(identity, opts, fn current, request_id ->
      with :ok <- input_size(params),
           {:ok, params} <- Request.validate(params),
           {:ok, policy, current} <- Policies.snapshot_for_models(current, opts[:agent_id]) do
        result = process_chat(current, params, policy, request_id, opts)

        {result, policy}
      else
        error -> {error, nil}
      end
    end)
  end

  defp process_chat(current, params, policy, request_id, opts) do
    with :ok <- Policies.model_access(current, policy, opts[:agent_id], params["model"]),
         {:ok, safe} <- Stages.evaluate(params, current, policy, request_id, :input),
         {:ok, safe} <- Request.validate(safe),
         :ok <- authorize_again(current, policy, opts[:agent_id], params["model"]),
         {:ok, response} <- generate(safe),
         {:ok, response} <- Response.normalize(response, params["model"], request_id),
         {:ok, response} <- Stages.evaluate(response, current, policy, request_id, :output) do
      Response.normalize(response, params["model"], request_id)
    end
  end

  def models(identity, opts \\ []) do
    execute(identity, opts, fn current, _ ->
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

          {{:ok, %{"object" => "list", "data" => data}}, policy}

        error ->
          {error, nil}
      end
    end)
  end

  defp execute(identity, opts, callback) do
    request_id = opts[:request_id] || Ecto.UUID.generate()
    started = System.monotonic_time()

    case Policies.refresh_identity(identity) do
      {:ok, current} ->
        {result, policy} =
          case ingress(current, opts) do
            :ok -> callback.(current, request_id)
            error -> {error, nil}
          end

        finish(current, request_id, result, policy, started)

      {:error, :forbidden} = error ->
        # These are trusted adapters whose previously verified access was revoked.
        case identity do
          %Principal{} -> finish(identity, request_id, error, nil, started)
          %Scope{} -> finish(identity, request_id, error, nil, started)
          _ -> error
        end
    end
  rescue
    _ -> {:error, :policy_unavailable}
  catch
    :exit, _ -> {:error, :upstream_unavailable}
  end

  defp finish(identity, request_id, result, policy, started) do
    code =
      case result do
        {:ok, _} -> "completed"
        {:error, {code, _}} -> Atom.to_string(code)
        {:error, code} -> Atom.to_string(code)
      end

    duration = duration(started)

    :telemetry.execute([:ai_control, :gateway, :request], %{duration_us: duration}, %{
      code: code
    })

    case Audit.record_gateway(identity, request_id, code, duration, policy) do
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

  defp generate(params) do
    measure(:generation, fn ->
      Slots.run(:llm, Config.get(:llm_timeout), fn -> provider_chat(params) end)
    end)
  end

  defp provider_chat(params) do
    config = Config.get()
    provider = config[:provider]

    with {:ok, models} <- provider.models(config),
         {:ok, digest} <- Models.digest(params["model"]),
         :ok <- pinned(models, params["model"], digest) do
      provider.chat(params, config)
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

  def measure(stage, callback) do
    started = System.monotonic_time()

    try do
      callback.()
    after
      :telemetry.execute([:ai_control, :gateway, :stage], %{duration_us: duration(started)}, %{
        stage: stage
      })
    end
  end

  defp duration(started),
    do: System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
end
