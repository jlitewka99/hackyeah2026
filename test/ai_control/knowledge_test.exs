defmodule AiControl.KnowledgeTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.GatewayFixtures
  import AiControl.KnowledgeFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.Audit.{Event, Serializer}
  alias AiControl.Gateway.Config
  alias AiControl.{Knowledge, Repo}
  alias AiControl.Knowledge.Resource
  alias AiControl.Organizations.Membership
  alias AiControl.Security.GuardResult
  alias Ecto.Adapters.SQL

  setup do
    old = Application.fetch_env!(:ai_control, Config)
    Application.put_env(:ai_control, Config, Keyword.put(old, :requests_per_minute, 10_000))
    on_exit(fn -> Application.put_env(:ai_control, Config, old) end)
    scope = organization_fixture()
    agent = agent_fixture(scope)
    principal = principal_fixture(scope, agent)
    activate_knowledge_policy(scope)
    %{scope: scope, agent: agent, principal: principal}
  end

  test "Knowledge is opt-in and legacy policies remain disabled", c do
    activate_gateway_policy(c.scope)
    assert {:error, :knowledge_disabled} = Knowledge.create(c.scope, document_attrs(c.agent))
    refute Repo.exists?(Resource)
  end

  test "private memory, explicit sharing and owner-only writes", c do
    second = agent_fixture(c.scope)
    reader = principal_fixture(c.scope, second)

    assert {:ok, memory} =
             Knowledge.create(c.principal, %{
               "title" => "Preference",
               "content" => "The user prefers concise support responses."
             })

    assert memory["kind"] == "memory"
    assert memory["owner_agent_id"] == c.agent.id
    assert {:error, :forbidden} = Knowledge.get(reader, memory["id"])

    assert {:ok, shared} =
             Knowledge.update(c.scope, memory["id"], %{
               "revision" => 1,
               "shared_agent_ids" => [second.id]
             })

    assert shared["revision"] == 2
    assert {:ok, _} = Knowledge.get(reader, memory["id"])

    assert {:error, :forbidden} =
             Knowledge.update(reader, memory["id"], %{"revision" => 2, "content" => "tampered"})

    assert {:ok, updated} =
             Knowledge.update(c.principal, memory["id"], %{
               "revision" => 2,
               "content" => "The user prefers longer responses."
             })

    assert updated["shared_agent_ids"] == [second.id]
  end

  test "cross-organization identifiers and shares cannot cross the database boundary", c do
    other = organization_fixture()
    stranger = agent_fixture(other)
    activate_knowledge_policy(other)
    document = document_fixture(c.scope, c.agent)
    assert {:error, :forbidden} = Knowledge.get(other, document["id"])

    assert {:error, :forbidden} =
             Knowledge.update(c.scope, document["id"], %{
               "revision" => 1,
               "shared_agent_ids" => [stranger.id]
             })

    assert {:error, :forbidden} = Knowledge.create(c.scope, document_attrs(stranger))

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             SQL.query(
               Repo,
               "INSERT INTO knowledge_shares (organization_id, resource_id, agent_id) VALUES ($1, $2, $3)",
               Enum.map([other.organization.id, document["id"], stranger.id], &Ecto.UUID.dump!/1),
               mode: :savepoint
             )
  end

  test "individual grants constrain both reads and writes without requiring ai.use", c do
    document = document_fixture(c.scope, c.agent)

    %{scope: reader} =
      member_fixture(c.scope, :user, %{permissions: ["knowledge.read"], agents: [c.agent.id]})

    assert {:ok, _} = Knowledge.get(reader, document["id"])
    assert {:error, :forbidden} = Knowledge.create(reader, document_attrs(c.agent))

    %{scope: empty} =
      member_fixture(c.scope, :user, %{permissions: ["knowledge.read"], agents: []})

    assert {:ok, []} = Knowledge.list(empty)
    assert {:error, :forbidden} = Knowledge.get(empty, document["id"])
  end

  test "search filters access before ranking and returns deterministic ties", c do
    private_agent = agent_fixture(c.scope)

    hidden =
      document_fixture(c.scope, private_agent, %{"content" => "support support support support"})

    a = document_fixture(c.scope, c.agent)
    b = document_fixture(c.scope, c.agent)
    assert {:ok, matches} = Knowledge.search(c.principal, %{"query" => "support"})
    assert Enum.map(matches, & &1["id"]) == Enum.sort([a["id"], b["id"]])
    refute Enum.any?(matches, &(&1["id"] == hidden["id"]))
  end

  test "current policy rescans stored text and only redacted text is indexed", c do
    document =
      document_fixture(c.scope, c.agent, %{"content" => "Support contact alice@example.com"})

    guards = %{
      "pii" => %{"enabled" => true, "required" => true},
      "secret" => %{"enabled" => false, "required" => false},
      "signatures" => %{"enabled" => false, "required" => false},
      "semantic" => %{"enabled" => false, "required" => false},
      "ner" => %{"enabled" => false, "required" => false}
    }

    Application.put_env(
      :ai_control,
      Config,
      Keyword.put(Config.get(), :guards, %{"pii" => AiControl.Guards.Pii})
    )

    activate_knowledge_policy(c.scope, %{"guards" => guards})
    assert {:ok, checked} = Knowledge.get(c.principal, document["id"])
    refute checked["content"] =~ "alice@example.com"
    assert checked["content"] =~ "[REDACTED]"

    assert {:ok, saved} =
             Knowledge.create(
               c.scope,
               document_attrs(c.agent, %{"content" => "Support alice@example.com"})
             )

    refute Repo.get!(Resource, saved["id"]).content =~ "alice@example.com"

    activate_knowledge_policy(c.scope, %{
      "guards" => guards,
      "rules" => %{"pii" => %{"action" => "block"}}
    })

    assert {:error, :policy_blocked} = Knowledge.get(c.principal, document["id"])
    before_count = Repo.aggregate(Resource, :count)

    assert {:error, :policy_blocked} =
             Knowledge.create(
               c.scope,
               document_attrs(c.agent, %{"content" => "alice@example.com"})
             )

    assert Repo.aggregate(Resource, :count) == before_count
    assert {:ok, _} = Knowledge.delete(c.scope, document["id"], 1)
  end

  test "revisions prevent lost updates and deletion removes search results", c do
    document = document_fixture(c.scope, c.agent)

    assert {:ok, updated} =
             Knowledge.update(c.scope, document["id"], %{
               "revision" => 1,
               "content" => "Updated support schedule"
             })

    assert updated["last_action"] == "allow"

    assert {:error, :knowledge_conflict} =
             Knowledge.update(c.scope, document["id"], %{"revision" => 1, "content" => "Stale"})

    assert {:error, :knowledge_conflict} = Knowledge.delete(c.scope, document["id"], 1)
    assert {:ok, _} = Knowledge.delete(c.scope, document["id"], 2)
    assert {:ok, []} = Knowledge.search(c.principal, %{"query" => "support"})
  end

  test "bounds reject excess bytes and invalid UTF-8 without truncation", c do
    assert {:error, :input_too_large} =
             Knowledge.create(
               c.scope,
               document_attrs(c.agent, %{"content" => String.duplicate("x", 65_537)})
             )

    assert {:error, :input_too_large} =
             Knowledge.create(c.principal, %{
               "title" => "Large",
               "content" => String.duplicate("x", 16_385)
             })

    assert {:error, :invalid_request} =
             Knowledge.create(c.scope, document_attrs(c.agent, %{"content" => <<255>>}))

    assert {:error, :invalid_request} =
             Knowledge.search(c.principal, %{"query" => "support", "top_k" => 11})

    for _ <- 1..3,
        do:
          document_fixture(c.scope, c.agent, %{
            "content" => "support " <> String.duplicate("x", 65_500)
          })

    assert {:error, :input_too_large} = Knowledge.search(c.principal, %{"query" => "support"})
  end

  test "agent cannot forge ownership, sharing or elevated trust", c do
    for attrs <- [
          %{"owner_agent_id" => c.agent.id},
          %{"trust_level" => "internal"},
          %{"shared_agent_ids" => [c.agent.id]},
          %{"kind" => "document"}
        ] do
      assert {:error, :forbidden} =
               Knowledge.create(
                 c.principal,
                 Map.merge(%{"title" => "Note", "content" => "A note"}, attrs)
               )
    end

    activate_knowledge_policy(c.scope, %{"knowledge" => %{"enabled" => true}})

    assert {:error, :knowledge_write_disabled} =
             Knowledge.create(c.principal, %{"title" => "Note", "content" => "A note"})
  end

  test "terminal audit failure rolls back resource changes and shares", c do
    SQL.query!(
      Repo,
      "ALTER TABLE audit_events ADD CONSTRAINT reject_knowledge CHECK (event_type <> 'knowledge.created')",
      []
    )

    assert {:error, :audit_unavailable} = Knowledge.create(c.scope, document_attrs(c.agent))
    refute Repo.exists?(Resource)
  end

  test "audit and serializer expose only bounded identifiers", c do
    document =
      document_fixture(c.scope, c.agent, %{
        "title" => "DO-NOT-LOG-TITLE",
        "content" => "DO-NOT-LOG-CONTENT",
        "source_reference" => "DO-NOT-LOG-SOURCE"
      })

    events = Repo.all(from(e in Event, where: e.event_type == "knowledge.created"))
    assert [event] = events
    exported = Serializer.event(event) |> Jason.encode!()
    refute exported =~ "DO-NOT-LOG"
    assert exported =~ document["id"]

    assert Serializer.data(%{
             "knowledge" => %{
               "operation" => "knowledge.read",
               "resources" => [%{"content" => "DO-NOT-LOG"}]
             }
           }) == %{}
  end

  test "ACL revocation during a write scan prevents persistence", c do
    member =
      member_fixture(c.scope, :user, %{
        permissions: ["knowledge.read", "knowledge.manage"],
        agents: [c.agent.id]
      })

    parent = self()

    Application.put_env(
      :ai_control,
      Config,
      Config.get()
      |> Keyword.put(:guards, %{"pii" => AiControl.TestGatewayGuard})
      |> Keyword.put(:test_guard, fn _, _ ->
        send(parent, {:scanning, self()})

        receive do
          :continue -> GuardResult.new(%{guard: "pii", status: :ok})
        end
      end)
    )

    activate_knowledge_policy(c.scope, %{
      "guards" => %{"pii" => %{"enabled" => true, "required" => true}}
    })

    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Knowledge.create(member.scope, document_attrs(c.agent))
      end)

    assert_receive {:scanning, worker}
    membership = Repo.get!(Membership, member.membership.id)
    Repo.update!(Ecto.Changeset.change(membership, grants: %{agents: []}))
    send(worker, :continue)
    assert {:error, :forbidden} = Task.await(task)
    refute Repo.exists?(Resource)
  end

  test "list pagination follows ACL filtering and has disjoint pages", c do
    first = document_fixture(c.scope, c.agent)
    second = document_fixture(c.scope, c.agent)
    hidden_agent = agent_fixture(c.scope)
    document_fixture(c.scope, hidden_agent)
    assert {:ok, [one]} = Knowledge.list(c.principal, %{"top_k" => 1, "page" => 1})
    assert {:ok, [two]} = Knowledge.list(c.principal, %{"top_k" => 1, "page" => 2})
    assert Enum.sort([one["id"], two["id"]]) == Enum.sort([first["id"], second["id"]])
    assert {:ok, []} = Knowledge.list(c.principal, %{"top_k" => 1, "page" => 3})
    assert {:error, :invalid_request} = Knowledge.list(c.principal, %{"page" => 0})
  end
end
