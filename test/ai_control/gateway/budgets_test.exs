defmodule AiControl.Gateway.BudgetsTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.OrganizationsFixtures
  import AiControl.SecurityFixtures

  alias AiControl.Audit.Event
  alias AiControl.Budgets.{Bucket, Reservation}
  alias AiControl.{Gateway, Repo}
  alias AiControl.Gateway.Config
  alias AiControl.Policies.Configuration
  alias AiControl.Security.GuardResult
  alias Ecto.Adapters.SQL

  setup do
    old = Application.fetch_env!(:ai_control, Config)

    Application.put_env(
      :ai_control,
      Config,
      old
      |> Keyword.put(:http_plug, {Req.Test, __MODULE__})
      |> Keyword.put(:tokenizer, AiControl.TestBudgetTokenizer)
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    scope = organization_fixture()
    agent = agent_fixture(scope)
    principal = principal_fixture(scope, agent)

    activate_gateway_policy(scope, %{
      "budgets" => %{"organization" => %{"tokens_per_hour" => 5000}}
    })

    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{
            models: [%{name: "qwen3.5:4b", digest: String.duplicate("a", 64)}]
          })

        "/api/version" ->
          Req.Test.json(conn, %{version: "0.35.1"})

        _ ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          params = Jason.decode!(body)
          if callback = Config.get()[:test_transport], do: callback.(params)

          if params["_debug_render_only"] do
            send(owner, {:render, params})

            Req.Test.json(conn, %{
              _debug_info: %{rendered_template: Jason.encode!(params["messages"])}
            })
          else
            send(owner, {:generate, params})
            Req.Test.json(conn, Config.get()[:test_response] || response())
          end
      end
    end)

    %{scope: scope, agent: agent, principal: principal}
  end

  defp bucket(context),
    do:
      Repo.get_by!(Bucket, organization_id: context.scope.organization.id, level: "organization")

  test "missing max_tokens is capped and usage is settled before returning", context do
    assert {:ok, _} = Gateway.chat(context.principal, request())
    assert_received {:generate, %{"max_tokens" => 1024}}
    assert bucket(context).tokens == 16
    assert bucket(context).reserved == 0
    assert bucket(context).requests == 1
  end

  test "token refusal counts an admitted request without generating", context do
    activate_gateway_policy(context.scope, %{
      "budgets" => %{"organization" => %{"tokens_per_hour" => 1}}
    })

    assert {:error, {:token_budget_exceeded, _}} = Gateway.chat(context.principal, request())
    refute_received {:generate, _}
    assert bucket(context).requests == 1
    assert bucket(context).tokens == 0
    assert bucket(context).reserved == 0
  end

  test "request refusal runs no expensive guards or backend preparation", context do
    activate_gateway_policy(context.scope, %{
      "budgets" => %{"organization" => %{"requests_per_hour" => 0}}
    })

    assert {:error, {:request_budget_exceeded, _}} = Gateway.chat(context.principal, request())
    refute_received {:render, _}
    refute_received {:generate, _}

    refute Repo.exists?(
             from(r in Reservation, where: r.organization_id == ^context.scope.organization.id)
           )
  end

  test "failed token counting is a confirmed unsent request", context do
    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :test_tokenizer, fn _, _ -> {:error, :tokenizer_unavailable} end)
    )

    assert {:error, :tokenizer_unavailable} = Gateway.chat(context.principal, request())
    refute_received {:generate, _}
    assert bucket(context).requests == 1
    assert bucket(context).reserved == 0
  end

  test "missing usage conservatively holds the reservation", context do
    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :test_response, Map.delete(response(), "usage"))
    )

    assert {:error, :upstream_invalid_response} =
             Gateway.chat(context.principal, Map.put(request(), "max_tokens", 100))

    assert bucket(context).reserved == 112

    assert Repo.get_by!(Reservation, organization_id: context.scope.organization.id).status ==
             "uncertain"
  end

  test "valid usage from malformed content is still charged", context do
    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :test_response, Map.put(response(), "choices", []))
    )

    assert {:error, :upstream_invalid_response} = Gateway.chat(context.principal, request())
    assert bucket(context).tokens == 16
    assert bucket(context).reserved == 0
  end

  test "output audit failure does not undo model usage", context do
    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT budget_reject_output CHECK (stage <> 'output')",
      []
    )

    assert {:error, :audit_unavailable} = Gateway.chat(context.principal, request())
    assert bucket(context).tokens == 16
    assert bucket(context).reserved == 0
  end

  test "failed input audit consumes a request but no tokens", context do
    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT budget_reject_input CHECK (kind <> 'decision')",
      []
    )

    assert {:error, :audit_unavailable} = Gateway.chat(context.principal, request())
    refute_received {:render, _}
    refute_received {:generate, _}
    assert bucket(context).requests == 1
    assert bucket(context).tokens == 0
  end

  test "timeout before dispatch releases tokens; timeout after dispatch retains them", context do
    owner = self()

    for phase <- [:prepare, :generate] do
      Application.put_env(
        :ai_control,
        Config,
        Config.get()
        |> Keyword.put(:llm_timeout, 100)
        |> Keyword.put(:test_transport, fn params ->
          current = if params["_debug_render_only"], do: :prepare, else: :generate

          if current == phase do
            send(owner, {:waiting, self()})

            receive do
              :continue -> :ok
            end
          end
        end)
      )

      assert {:error, :upstream_timeout} = Gateway.chat(context.principal, request())
      assert_received {:waiting, pid}
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      expected = if phase == :prepare, do: 0, else: 1036
      assert bucket(context).reserved == expected
    end
  end

  test "a killed generation worker retains its dispatched reservation", context do
    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :test_transport, fn params ->
        if !params["_debug_render_only"], do: Process.exit(self(), :kill)
      end)
    )

    assert {:error, :upstream_timeout} = Gateway.chat(context.principal, request())
    assert bucket(context).reserved == 1036

    assert Repo.get_by!(Reservation, organization_id: context.scope.organization.id).status ==
             "uncertain"
  end

  test "redacted input is counted and guard usage remains separate from model tokens", context do
    activate_gateway_policy(context.scope, %{
      "budgets" => %{"organization" => %{"tokens_per_hour" => 5000}},
      "guards" => guards(%{"enabled" => true, "required" => true})
    })

    owner = self()
    guard_usage = %{"prompt_tokens" => 100, "completion_tokens" => 2, "total_tokens" => 102}

    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:guards, %{"pii" => AiControl.TestGatewayGuard})
      |> Keyword.put(:test_guard, fn fields, context ->
        detections =
          if context.stage == :input,
            do: [
              detection_fixture(%{
                location: %{
                  field_index: Enum.find_index(fields, &String.contains?(&1, "Zażółć")),
                  start_byte: 0,
                  end_byte: byte_size("Zażółć gęślą jaźń")
                }
              })
            ],
            else: []

        GuardResult.new(%{guard: "pii", status: :ok, detections: detections, usage: guard_usage})
      end)
      |> Keyword.put(:test_tokenizer, fn _, prompt ->
        send(owner, {:counted, prompt})
        {:ok, 12}
      end)
    )

    assert {:ok, _} = Gateway.chat(context.principal, request())
    assert_received {:counted, prompt}
    assert prompt =~ "[REDACTED]"
    refute prompt =~ "Zażółć"
    assert bucket(context).tokens == 16
    decisions = Repo.all(from(e in Event, where: e.kind == :decision))

    assert Enum.all?(decisions, fn e ->
             Enum.any?(e.data["guards"], &(&1["usage"] == guard_usage))
           end)
  end

  test "output blocking still settles usage", context do
    activate_gateway_policy(context.scope, %{
      "budgets" => %{"organization" => %{"tokens_per_hour" => 5000}},
      "guards" => guards(%{"enabled" => true, "required" => true, "stages" => ["output"]}),
      "rules" => %{"pii" => %{"action" => "block"}}
    })

    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:guards, %{"pii" => AiControl.TestGatewayGuard})
      |> Keyword.put(:test_guard, fn fields, _ ->
        index = Enum.find_index(fields, &String.contains?(&1, "Bezpieczna"))

        GuardResult.new(%{
          guard: "pii",
          status: :ok,
          detections: [
            detection_fixture(%{location: %{field_index: index, start_byte: 0, end_byte: 1}})
          ]
        })
      end)
    )

    assert {:error, :policy_blocked} = Gateway.chat(context.principal, request())
    assert bucket(context).tokens == 16
    assert bucket(context).reserved == 0
    event = Repo.one!(from(e in Event, where: e.kind == :gateway))
    assert event.data["operation"] == "chat"
    assert event.data["budget"]["usage"]["total_tokens"] == 16
    assert event.data["budget"]["status"] == "settled"

    assert Enum.all?(
             ~w(request input output upstream budget_admission budget_reservation budget_settlement guard.output.pii),
             fn key ->
               is_integer(event.data["timings"][key]) && event.data["timings"][key] >= 0
             end
           )
  end

  defp guards(pii) do
    Configuration.guards()
    |> Map.new(&{&1, %{"enabled" => false, "required" => false}})
    |> Map.put("pii", pii)
  end

  test "database failure prevents generation", context do
    SQL.query!(
      Repo,
      "ALTER TABLE budget_reservations ADD CONSTRAINT reject_budget_admission CHECK (status <> 'admitted')",
      []
    )

    assert {:error, :budget_unavailable} = Gateway.chat(context.principal, request())
    refute_received {:render, _}
    refute_received {:generate, _}
  end
end
