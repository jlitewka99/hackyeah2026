defmodule AiControl.Testing.Suite do
  @moduledoc "Synthetic HTTP scenarios exercise the real gateway, durable budgets and sandbox."
  import Ecto.Query

  alias AiControl.{Accounts, Agents, ApiKeys, Organizations, Policies, Repo, Workflows}
  alias AiControl.Accounts.Scope
  alias AiControl.Audit.Event
  alias AiControl.Benchmarks.Semantic
  alias AiControl.Budgets.Bucket
  alias AiControl.Budgets.Tokenizer
  alias AiControl.Gateway.Config
  alias AiControl.Gateway.DeepSeek
  alias AiControl.Gateway.Models
  alias AiControl.Guards.Ner
  alias AiControl.Guards.Semantic.Local
  alias AiControl.Guards.Semantic.PromptGuard
  alias AiControl.Policies.Configuration
  alias AiControl.Testing.State
  alias AiControl.Tools.{Catalog, Sandbox}

  @cases ~w(allow input_redaction output_redaction secret_block exploit_block required_guard request_budget token_budget output_block_accounting tool_allow tool_acl tool_output tool_budget snapshot revoked_key)
  def case_ids, do: @cases
  def expected_ids(%{"suite" => "gateway.v1", "mode" => "controlled"}), do: @cases

  def expected_ids(%{"suite" => "gateway.v1", "mode" => "live"}),
    do: @cases ++ ["live.gateway"] ++ Semantic.case_ids()

  def expected_ids(%{"suite" => "semantic-pl.v1", "mode" => "live"}),
    do: ["live.gateway"] ++ Semantic.case_ids()

  def run(origin, emit) do
    Enum.map(@cases, fn id ->
      started = System.monotonic_time(:microsecond)
      result = scenario(id, origin)

      row = %{
        "case_id" => id,
        "status" => result.status,
        "duration_us" => System.monotonic_time(:microsecond) - started,
        "evidence" => result.evidence
      }

      emit.(row)
      row
    end)
  end

  def live(origin, emit) do
    config = Config.get()

    checks = [
      Ner.ready?(config),
      Local.ready?(config),
      PromptGuard.ready?(config),
      Tokenizer.ready?(config)
    ]

    with true <- Enum.all?(checks),
         {:ok, models} <- DeepSeek.models(config),
         true <-
           Enum.all?(config[:models], fn {name, _} -> Map.has_key?(models, name) end) &&
             map_size(config[:models]) > 0 do
      Application.put_env(
        :ai_control,
        Config,
        Keyword.merge(config,
          provider: DeepSeek,
          tokenizer: Tokenizer
        )
      )

      started = System.monotonic_time(:microsecond)
      context = fixture("live", %{"guards" => %{}, "budgets" => %{}})
      response = chat(context, origin, "Napisz jedno krótkie zdanie o pogodzie.")
      evidence = evidence(context, response)

      row = %{
        "case_id" => "live.gateway",
        "status" => if(response.status == 200, do: "passed", else: "failed"),
        "duration_us" => System.monotonic_time(:microsecond) - started,
        "evidence" => evidence
      }

      emit.(row)
      benchmark(emit)
      :ok
    else
      _ -> {:error, :runner_unavailable}
    end
  rescue
    _ -> {:error, :runner_failed}
  end

  def benchmark(emit) do
    Enum.each(~w(qwen prompt_guard), fn provider ->
      Semantic.measure(provider, fn row ->
        status = benchmark_status(row)

        emit.(%{
          "case_id" => provider <> "." <> String.downcase(row["id"]),
          "status" => status,
          "duration_us" => row["duration_us"],
          "evidence" => %{
            "provider" => provider,
            "dataset_checksum" => row["dataset_checksum"],
            "expected_block" => row["expected_block"],
            "observed_block" => row["blocked"]
          }
        })
      end)
    end)

    :ok
  end

  defp benchmark_status(row) do
    cond do
      row["error"] -> "error"
      row["blocked"] == row["expected_block"] -> "passed"
      true -> "failed"
    end
  end

  defp scenario(id, origin) do
    config = Config.get()
    State.reset()

    try do
      overrides = overrides(id)
      context = fixture(id, overrides)
      scenario_result(id, origin, context, config)
    rescue
      _ -> %{status: "error", evidence: %{}}
    after
      Application.put_env(:ai_control, Config, config)
      State.reset()
    end
  end

  defp scenario_result(id, origin, context, config) do
    configure(id, context, config)
    response = execute(id, context, origin)
    passed? = response.status == expected_status(id) && verify(id, context, response)
    %{status: if(passed?, do: "passed", else: "failed"), evidence: evidence(context, response)}
  after
    Workflows.transition(context.scope, context.run_id, "stop")
  end

  defp fixture(id, overrides) do
    {:ok, {user, _}} =
      Accounts.bootstrap_organizer("runner@example.invalid", "Synthetic-runner-password-2026")

    organizer = Scope.for_user(user)

    {:ok, org} =
      Organizations.create_organization(organizer, %{
        name: "Synthetic #{id} #{Ecto.UUID.generate()}"
      })

    {:ok, scope} = Organizations.fetch_scope(organizer, org.id)
    {:ok, agent} = Agents.create_agent(scope, %{name: "Synthetic agent"})
    {:ok, {_key, token}} = ApiKeys.create_key(scope, agent.id, %{label: "Synthetic runner"})
    source = source(overrides)
    version = activate(scope, source)

    opts = [
      name: AiControl.Tools.Config.via(org.id),
      organization_id: org.id,
      contexts: %{agent.id => Ecto.UUID.generate()},
      grants: %{
        agent.id => %{
          paths: ["report.txt", "sensitive.txt"],
          tables: [],
          recipients: [],
          commands: [],
          endpoints: %{}
        }
      },
      files: %{"report.txt" => "Synthetic safe file", "sensitive.txt" => "eval('synthetic')"},
      tables: %{}
    ]

    {:ok, _} =
      Supervisor.start_child(
        AiControl.Tools.Supervisor,
        Supervisor.child_spec({Sandbox, opts}, id: org.id)
      )

    {:ok, principal} = ApiKeys.authenticate(token)

    {:ok, {run, participant}} =
      Workflows.create(
        principal,
        %{"goal" => "Synthetic gateway acceptance scenario"},
        Ecto.UUID.generate()
      )

    %{
      scope: scope,
      agent: agent,
      token: token,
      source: source,
      version: version,
      run_id: run.id,
      participant_id: participant.id
    }
  end

  defp source(overrides) do
    guards =
      Map.new(Configuration.guards(5), fn guard ->
        {guard,
         if(guard in ~w(ner semantic moderation),
           do: %{"enabled" => false, "required" => false},
           else: %{"enabled" => true, "required" => true}
         )}
      end)

    Configuration.default(5)
    |> Map.put("allowed_models", Models.all())
    |> Map.put("guards", guards)
    |> Map.put("tools", %{"allowed_tools" => Enum.map(Catalog.all(), & &1["name"])})
    |> Map.merge(overrides)
  end

  defp activate(scope, source) do
    {:ok, version} = Policies.create_version(scope, source)
    {:ok, current} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    version
  end

  defp overrides("request_budget"),
    do: %{"budgets" => %{"organization" => %{"requests_per_hour" => 0}}}

  defp overrides("token_budget"),
    do: %{"budgets" => %{"organization" => %{"tokens_per_hour" => 1}}}

  defp overrides("tool_budget"), do: %{"budgets" => %{"workflow" => %{"tool_calls" => 0}}}

  defp overrides("output_block_accounting"),
    do: %{"budgets" => %{"organization" => %{"tokens_per_hour" => 5000}}}

  defp overrides(_), do: %{}

  defp configure("output_redaction", _, _),
    do: State.put(:content, "Contact synthetic@example.invalid")

  defp configure("output_block_accounting", _, _), do: State.put(:content, "eval('synthetic')")

  defp configure("required_guard", _, config),
    do:
      Application.put_env(
        :ai_control,
        Config,
        Keyword.put(
          config,
          :guards,
          Map.put(config[:guards], "signatures", AiControl.Testing.UnavailableGuard)
        )
      )

  defp configure("snapshot", context, _) do
    State.put(:before_response, fn ->
      activate(
        context.scope,
        Map.put(context.source, "rules", %{"pii" => %{"action" => "block"}})
      )
    end)

    State.put(:content, "Contact synthetic@example.invalid")
  end

  defp configure("revoked_key", context, _) do
    {:ok, principal} = ApiKeys.authenticate(context.token)
    {:ok, _} = ApiKeys.revoke_key(context.scope, principal.api_key_id)
  end

  defp configure(_, _, _), do: :ok

  defp execute(id, context, origin) when id in ~w(tool_allow tool_acl tool_output tool_budget) do
    path =
      case id do
        "tool_acl" -> "../../.ssh/id_rsa"
        "tool_output" -> "sensitive.txt"
        _ -> "report.txt"
      end

    request(context, origin, "/v1/tool_calls", %{
      "tool" => "file.read",
      "arguments" => %{"path" => path}
    })
  end

  defp execute("input_redaction", context, origin),
    do: chat(context, origin, "Contact synthetic@example.invalid")

  defp execute("secret_block", context, origin),
    do: chat(context, origin, "-----BEGIN PRIVATE KEY-----\nsynthetic")

  defp execute("exploit_block", context, origin), do: chat(context, origin, "eval('synthetic')")
  defp execute(_, context, origin), do: chat(context, origin, "Synthetic safe request")

  defp chat(context, origin, text),
    do:
      request(context, origin, "/v1/chat/completions", %{
        "model" => hd(Models.all()),
        "messages" => [%{"role" => "user", "content" => text}],
        "max_tokens" => 32
      })

  defp request(context, origin, path, body) do
    Req.post!(origin <> path,
      json: body,
      auth: {:bearer, context.token},
      retry: false,
      redirect: false,
      receive_timeout: 180_000,
      request_timeout: 180_000,
      headers: [
        {"idempotency-key", Ecto.UUID.generate()},
        {"x-run-id", context.run_id},
        {"x-run-participant-id", context.participant_id}
      ]
    )
  end

  defp expected_status(id)
       when id in ~w(secret_block exploit_block output_block_accounting tool_acl tool_output),
       do: 403

  defp expected_status(id) when id in ~w(request_budget token_budget tool_budget), do: 429
  defp expected_status("required_guard"), do: 503
  defp expected_status("revoked_key"), do: 401
  defp expected_status(_), do: 200

  defp verify("input_redaction", _, _),
    do: !String.contains?(Jason.encode!(State.get(:messages)), "synthetic@example.invalid")

  defp verify(id, _, response) when id in ~w(output_redaction snapshot),
    do: !String.contains?(Jason.encode!(response.body), "synthetic@example.invalid")

  defp verify("output_block_accounting", context, _) do
    bucket =
      Repo.get_by!(Bucket, organization_id: context.scope.organization.id, level: "organization")

    bucket.tokens == 16 && bucket.reserved == 0
  end

  defp verify(_, _, _), do: true

  defp evidence(context, response) do
    bucket =
      Repo.get_by(Bucket, organization_id: context.scope.organization.id, level: "organization")

    count =
      Repo.aggregate(
        from(e in Event, where: e.organization_id == ^context.scope.organization.id),
        :count
      )

    %{
      "http_status" => response.status,
      "audit_count" => count,
      "settled_tokens" => if(bucket, do: bucket.tokens, else: 0),
      "reserved_tokens" => if(bucket, do: bucket.reserved, else: 0),
      "request_count" => if(bucket, do: bucket.requests, else: 0)
    }
  end
end
