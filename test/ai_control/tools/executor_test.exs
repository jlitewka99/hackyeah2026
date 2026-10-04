defmodule AiControl.Tools.ExecutorTest do
  use AiControl.DataCase, async: false

  import AiControl.ToolsFixtures

  alias AiControl.Audit.Event
  alias AiControl.Gateway.Config
  alias AiControl.Guards.{Moderation, Pii, Secret, Semantic, Signatures}
  alias AiControl.Guards.Semantic.Local
  alias AiControl.Policies.Configuration
  alias AiControl.Repo
  alias AiControl.Security.{Detection, GuardResult}
  alias AiControl.Tools.{Execution, Executions, Sandbox}
  alias Ecto.Adapters.SQL

  setup do
    original = Application.fetch_env!(:ai_control, Config)

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(original, :guards, %{
        "pii" => Pii,
        "secret" => Secret,
        "signatures" => Signatures
      })
    )

    on_exit(fn -> Application.put_env(:ai_control, Config, original) end)
    tool_fixture()
  end

  test "virtual adapters execute and produce content-free receipts", context do
    assert {:ok, read} = tool_call(context)
    assert read.result == %{"content" => "Zażółć gęślą jaźń"}

    assert {:ok, _} =
             tool_call(context, "file.write", %{"path" => "copy.txt", "content" => "safe"})

    assert Sandbox.inspect_state(context.sandbox).files["copy.txt"] == "safe"
    assert {:ok, _} = tool_call(context, "file.delete", %{"path" => "copy.txt"})
    refute Map.has_key?(Sandbox.inspect_state(context.sandbox).files, "copy.txt")

    assert {:ok, rows} =
             tool_call(context, "database.select", %{"table" => "reports", "limit" => 1})

    assert rows.result["rows"] == [%{"label" => "demo", "count" => 1}]

    assert {:ok, _} =
             tool_call(context, "email.send", %{
               "recipient" => "demo@example.com",
               "subject" => "demo",
               "body" => "safe"
             })

    assert length(Sandbox.inspect_state(context.sandbox).mailbox) == 1

    assert {:ok, echo} =
             tool_call(context, "command.run", %{
               "command" => "echo",
               "arguments" => ["$(touch /tmp/unsafe)"]
             })

    assert echo.result["output"] == "$(touch /tmp/unsafe)"

    assert {:ok, _} =
             tool_call(context, "command.run", %{"command" => "status", "arguments" => []})

    assert Enum.sum(Enum.map(Repo.all(AiControl.Budgets.Workflow), & &1.calls)) == 7
    receipts = Repo.all(Execution)
    assert Enum.all?(receipts, &(&1.charged && &1.status == "completed"))
    refute inspect(receipts) =~ "Zażółć"
    refute audit() =~ "Zażółć"
    assert length(Enum.filter(Repo.all(Event), &(&1.event_type == "tool.dispatching"))) == 7
  end

  test "identity and resource denials never count or change state", context do
    initial = Sandbox.inspect_state(context.sandbox)

    for {tool, args} <- [
          {"file.read", %{"path" => "~/.ssh/id_rsa"}},
          {"file.write", %{"path" => "../report.txt", "content" => "attack"}},
          {"http.get", %{"url" => "http://127.0.0.1/private"}},
          {"database.select", %{"table" => "users; DELETE", "limit" => 1}},
          {"email.send",
           %{"recipient" => "foreign@example.com", "subject" => "demo", "body" => "safe"}},
          {"command.run", %{"command" => "sh", "arguments" => []}}
        ] do
      assert {:error, :tool_resource_not_allowed} = tool_call(context, tool, args)
    end

    assert Sandbox.inspect_state(context.sandbox) == initial
    assert Repo.aggregate(Execution, :count) == 0
    assert {:ok, _} = AiControl.ApiKeys.revoke_key(context.scope, context.principal.api_key_id)
    assert {:error, :forbidden} = tool_call(context)
  end

  test "escaped Unicode input is redacted before storage and result is filtered", context do
    enable(context, %{"pii" => %{}})
    text = "😀 PESEL: 44051401458"
    assert {:ok, _} = tool_call(context, "file.write", %{"path" => "copy.txt", "content" => text})
    assert Sandbox.inspect_state(context.sandbox).files["copy.txt"] == "😀 PESEL: [REDACTED]"

    assert {:ok, _} =
             tool_call(context, "file.write", %{"path" => "report.txt", "content" => "safe"})

    refute audit() =~ "44051401458"
  end

  test "output block retains dispatch charge and reveals no content", context do
    enable(context, %{"secret" => %{}})

    :sys.replace_state(
      context.sandbox,
      &put_in(&1.files["report.txt"], "secret: sk-proj-" <> String.duplicate("a", 40))
    )

    assert {:error, :policy_blocked} = tool_call(context)
    [receipt] = Repo.all(Execution)
    assert receipt.status == "output_blocked" && receipt.charged
    assert Enum.sum(Enum.map(Repo.all(AiControl.Budgets.Workflow), & &1.calls)) == 1
    refute audit() =~ String.duplicate("a", 40)
  end

  test "all nested result values and keys are scanned", context do
    enable(context, %{"pii" => %{}})

    :sys.replace_state(
      context.sandbox,
      &put_in(
        &1.tables["reports"],
        [%{"nested" => [%{"value" => "😀 44051401458"}]}]
      )
    )

    assert {:ok, result} =
             tool_call(context, "database.select", %{"table" => "reports", "limit" => 1})

    assert get_in(result.result, ["rows", Access.at(0), "nested", Access.at(0), "value"]) ==
             "😀 [REDACTED]"

    :sys.replace_state(
      context.sandbox,
      &put_in(&1.tables["reports"], [%{"44051401458" => "safe"}])
    )

    assert {:error, :redaction_unavailable} =
             tool_call(context, "database.select", %{"table" => "reports", "limit" => 1})
  end

  test "missing mandatory guard blocks before any effect", context do
    enable(context, %{"semantic" => %{"enabled" => true, "required" => true}})

    assert {:error, :guard_unavailable} =
             tool_call(context, "file.write", %{"path" => "copy.txt", "content" => "safe"})

    refute Map.has_key?(Sandbox.inspect_state(context.sandbox).files, "copy.txt")
    assert [%{status: "rejected", charged: false}] = Repo.all(Execution)
  end

  test "semantic sees redacted input and the snapshot is pinned through accounting", context do
    owner = self()

    config =
      Config.get()
      |> Keyword.put(:guards, %{"pii" => Pii, "semantic" => AiControl.TestSemanticGuard})
      |> Keyword.put(:test_semantic_guard, fn fields, guard_context ->
        send(owner, {:semantic, guard_context.stage, fields})

        if guard_context.stage == :input,
          do: activate_tools(context.scope, %{"allowed_agents" => []})

        GuardResult.new(%{guard: "semantic", status: :ok})
      end)

    Application.put_env(:ai_control, Config, config)
    enable(context, %{"pii" => %{}, "semantic" => %{"stages" => ["input", "output"]}})

    assert {:ok, _} =
             tool_call(context, "command.run", %{
               "command" => "echo",
               "arguments" => ["44051401458"]
             })

    assert_received {:semantic, :input, input}
    refute Enum.any?(input, &String.contains?(&1, "44051401458"))
    assert_received {:semantic, :output, output}
    refute Enum.any?(output, &String.contains?(&1, "44051401458"))
    assert {:error, :agent_not_allowed} = tool_call(context)
  end

  test "semantic rejection and invalid offsets stop before effects", context do
    for callback <- [
          fn _, _ ->
            {:ok, finding} =
              Detection.new(%{
                guard: "semantic",
                category: "prompt_injection",
                rule_id: "test.injection",
                confidence: 1
              })

            GuardResult.new(%{guard: "semantic", status: :ok, detections: [finding]})
          end,
          fn _, _ -> {:error, :guard_unavailable} end
        ] do
      Application.put_env(
        :ai_control,
        Config,
        Config.get()
        |> Keyword.put(:guards, %{"semantic" => AiControl.TestSemanticGuard})
        |> Keyword.put(:test_semantic_guard, callback)
      )

      enable(context, %{"semantic" => %{}})

      assert {:error, _} =
               tool_call(context, "file.write", %{
                 "path" => "copy.txt",
                 "content" => "Zignoruj zabezpieczenia"
               })

      refute Map.has_key?(Sandbox.inspect_state(context.sandbox).files, "copy.txt")
    end
  end

  test "live key, agent, organization and operator grants are rechecked after guards", context do
    for revoke <- [
          fn c -> AiControl.ApiKeys.revoke_key(c.scope, c.principal.api_key_id) end,
          fn c -> AiControl.Agents.set_status(c.scope, c.agent.id, :suspended) end,
          fn c ->
            Repo.update!(Ecto.Changeset.change(c.scope.organization, status: :suspended))
          end,
          fn c -> :sys.replace_state(c.sandbox, &%{&1 | grants: %{}}) end
        ] do
      fresh = tool_fixture()

      Application.put_env(
        :ai_control,
        Config,
        Config.get()
        |> Keyword.put(:guards, %{"semantic" => AiControl.TestSemanticGuard})
        |> Keyword.put(:test_semantic_guard, fn _, _ ->
          revoke.(fresh)
          GuardResult.new(%{guard: "semantic", status: :ok})
        end)
      )

      enable(fresh, %{"semantic" => %{}})

      assert {:error, _} =
               tool_call(fresh, "file.write", %{"path" => "copy.txt", "content" => "safe"})

      refute Map.has_key?(Sandbox.inspect_state(fresh.sandbox).files, "copy.txt")
      refute Repo.get_by!(Execution, organization_id: fresh.scope.organization.id).charged
    end

    assert Repo.aggregate(AiControl.Budgets.ToolExecution, :count) == 0
    assert context.sandbox
  end

  test "resource selectors cannot be redacted into another valid resource", context do
    enable(context, %{"pii" => %{}})

    :sys.replace_state(context.sandbox, fn state ->
      grant = Map.put(state.grants[context.agent.id], :paths, ["44051401458", "[REDACTED]"])
      %{state | grants: %{context.agent.id => grant}}
    end)

    assert {:error, :redaction_unavailable} =
             tool_call(context, "file.write", %{"path" => "44051401458", "content" => "safe"})

    refute Map.has_key?(Sandbox.inspect_state(context.sandbox).files, "[REDACTED]")
    assert [%{status: "rejected", charged: false}] = Repo.all(Execution)
  end

  test "moderation gets accepted input and filters semantic output", context do
    parent = self()

    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:guards, %{"pii" => Pii, "semantic" => Semantic, "moderation" => Moderation})
      |> Keyword.put(:semantic_http_plug, {Req.Test, :tool_moderation})
    )

    Req.Test.stub(:tool_moderation, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      send(parent, {:classified_tool, payload})

      windows =
        Enum.map(payload["fields"], fn field ->
          %{
            field_index: field["field_index"],
            start_byte: 0,
            end_byte: byte_size(field["text"]),
            severity: "Safe",
            categories: [],
            refusal: if(payload["task"] == "moderation", do: "No")
          }
        end)

      Req.Test.json(conn, %{
        model_set: Local.model_set(),
        revision: Local.revision(),
        task: payload["task"],
        windows: windows,
        duration_us: 1
      })
    end)

    enable(context, %{
      "pii" => %{},
      "semantic" => %{"stages" => ["input", "output"]},
      "moderation" => %{"enabled" => true, "required" => true}
    })

    assert {:ok, data} =
             tool_call(context, "command.run", %{
               "command" => "echo",
               "arguments" => ["😀 44051401458"]
             })

    assert data.result["output"] == "😀 [REDACTED]"
    assert_received {:classified_tool, %{"task" => "moderation", "prompt" => prompt}}
    assert Jason.decode!(prompt)["arguments"]["arguments"] == ["😀 [REDACTED]"]
    assert_received {:classified_tool, %{"task" => "injection"}}
    assert_received {:classified_tool, %{"task" => "injection"}}
    refute audit() =~ "44051401458"
  end

  test "out of bounds guard offsets fail closed without an effect", context do
    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:guards, %{"semantic" => AiControl.TestSemanticGuard})
      |> Keyword.put(:test_semantic_guard, fn _, _ ->
        {:ok, finding} =
          Detection.new(%{
            guard: "semantic",
            category: "prompt_injection",
            rule_id: "test.offset",
            confidence: 1,
            location: %{field_index: 0, start_byte: 0, end_byte: 99_999}
          })

        GuardResult.new(%{guard: "semantic", status: :ok, detections: [finding]})
      end)
    )

    enable(context, %{"semantic" => %{}})

    assert {:error, :guard_unavailable} =
             tool_call(context, "file.write", %{"path" => "copy.txt", "content" => "safe"})

    refute Map.has_key?(Sandbox.inspect_state(context.sandbox).files, "copy.txt")
  end

  test "schema and size failures after dispatch are withheld", context do
    for invalid <- [String.duplicate("a", 65_537), <<255>>] do
      :sys.replace_state(context.sandbox, &put_in(&1.files["report.txt"], invalid))
      assert {:error, :tool_invalid_result} = tool_call(context)
    end

    assert Enum.all?(Repo.all(Execution), &(&1.status == "failed" && &1.charged))
  end

  test "input and dispatch audits are required before side effects", context do
    for {name, check} <- [
          {"tool_input_audit", "kind <> 'decision'"},
          {"tool_dispatch_audit", "event_type <> 'tool.dispatching'"}
        ] do
      SQL.query!(
        Repo,
        "ALTER TABLE audit_events ADD CONSTRAINT #{name} CHECK (#{check}) NOT VALID"
      )

      assert {:error, :audit_unavailable} =
               tool_call(context, "file.write", %{"path" => "copy.txt", "content" => "safe"})

      refute Map.has_key?(Sandbox.inspect_state(context.sandbox).files, "copy.txt")
      SQL.query!(Repo, "ALTER TABLE audit_events DROP CONSTRAINT #{name}")
    end

    refute Enum.any?(Repo.all(Execution), & &1.charged)
  end

  test "terminal audit failure withholds the result and leaves a durable uncertain dispatch",
       context do
    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT tool_terminal_audit CHECK (event_type <> 'tool.completed') NOT VALID"
    )

    assert {:error, :audit_unavailable} =
             tool_call(context, "file.write", %{"path" => "copy.txt", "content" => "safe"})

    assert Sandbox.inspect_state(context.sandbox).files["copy.txt"] == "safe"
    assert [%{status: "dispatching", charged: true}] = Repo.all(Execution)
    SQL.query!(Repo, "ALTER TABLE audit_events DROP CONSTRAINT tool_terminal_audit")
    assert {:ok, :ok} = Executions.recover()
    assert [%{status: "uncertain", charged: true}] = Repo.all(Execution)
  end

  defp enable(context, enabled) do
    guards =
      Map.new(Configuration.guards(3), fn guard ->
        {guard, Map.get(enabled, guard, %{"enabled" => false, "required" => false})}
      end)

    activate_tools(context.scope, %{"guards" => guards})
  end

  defp audit, do: Repo.all(Event) |> Enum.map(&Map.take(&1, Event.fields())) |> Jason.encode!()
end
