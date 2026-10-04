defmodule AiControl.Audit.FilterExportTest do
  use AiControl.DataCase, async: true

  import AiControl.OrganizationsFixtures

  alias AiControl.{Audit, Organizations}
  alias AiControl.Audit.{Event, Export, Filters, Serializer}
  alias AiControl.Policies.Configuration

  test "validates cursor, UUID, enum, guard and UTC ranges without raising" do
    for params <- [
          %{"cursor" => "bad"},
          %{"cursor" => Base.url_encode64("[null,null]", padding: false)},
          %{"agent_id" => "wrong"},
          %{"kind" => "unknown"},
          %{"guard" => "invented"},
          %{"range" => "custom", "from" => "2026-10-04T02:00", "to" => "2026-10-04T01:00"}
        ] do
      assert {:error, %Ecto.Changeset{}} = Filters.parse(params)
    end

    assert {:ok, %{from: ~U[2026-10-04 01:00:00.000000Z]}} =
             Filters.parse(%{
               "range" => "custom",
               "from" => "2026-10-04T01:00",
               "to" => "2026-10-04T02:00"
             })
  end

  test "stable keyset pages and full export use the same filters without another tenant" do
    scope = organization_fixture()
    {:ok, event} = Audit.record_gateway(scope, Ecto.UUID.generate(), "completed", 3)
    insert_copies(event, 501)
    other = organization_fixture()
    {:ok, _} = Audit.record_gateway(other, Ecto.UUID.generate(), "completed", 3)
    {:ok, filters} = Filters.parse(%{"kind" => "gateway", "reason_code" => "completed"})
    assert {:ok, page} = Audit.page_events(scope, filters)
    assert length(page.events) == 50
    assert {:ok, next} = Audit.page_events(scope, %{filters | cursor: page.next})
    assert MapSet.disjoint?(MapSet.new(page.events, & &1.id), MapSet.new(next.events, & &1.id))

    assert {:ok, {batches, 502}} =
             Export.run(scope, filters, [], fn state, lines -> {:ok, [lines | state]} end)

    assert Enum.map(Enum.reverse(batches), &length/1) == [500, 2, 1]
    lines = batches |> Enum.reverse() |> List.flatten() |> Enum.map(&Jason.decode!/1)

    assert List.last(lines) == %{
             "type" => "export_complete",
             "schema_version" => 1,
             "count" => 502
           }

    assert Enum.all?(
             Enum.drop(lines, -1),
             &(&1["event"]["organization_id"] == scope.organization.id)
           )
  end

  test "both permissions are required and loss of access between batches never emits completion" do
    scope = organization_fixture()

    for permissions <- [["events.read"], ["events.export"], []] do
      reader = member_fixture(scope, :user, %{permissions: permissions})
      assert {:error, :forbidden} = Export.authorize(reader.scope)
    end

    reader = member_fixture(scope, :user, %{permissions: ["events.read", "events.export"]})
    {:ok, event} = Audit.record_gateway(scope, Ecto.UUID.generate(), "completed", 3)
    insert_copies(event, 500)
    {:ok, filters} = Filters.parse(%{"kind" => "gateway"})

    assert {:error, :export_interrupted} =
             Export.run(reader.scope, filters, nil, fn state, lines ->
               send(self(), {:batch, lines})

               {:ok, _} =
                 Organizations.update_member(scope, reader.membership.id, %{
                   grants: %{permissions: ["events.read"]}
                 })

               {:ok, state}
             end)

    assert_received {:batch, lines}
    assert length(lines) == 500
    refute_received {:batch, _}

    assert {:error, :export_interrupted} =
             Export.run(scope, filters, nil, fn _, _ -> {:error, :closed} end)
  end

  test "projection drops raw and unknown nested data from both UI and export" do
    secret = "sensitive-content-never-export"

    event = %Event{
      data: %{
        "prompt" => secret,
        "response" => secret,
        "failed_guards" => [%{"prompt" => secret}],
        "budget" => %{"cost" => %{"prompt" => secret}},
        "guards" => [
          %{
            "guard" => "semantic",
            "status" => "ok",
            "signals" => %{
              "injection_score" => 1,
              "risk_score" => %{"prompt" => secret},
              "raw" => secret
            },
            "evidence" => %{"raw" => secret},
            "content" => secret
          }
        ],
        "policy_evidence" => %{
          "settings" => %{"prompt" => secret},
          "required_guards" => ["semantic"]
        }
      }
    }

    projected = Serializer.event(event)
    refute Jason.encode!(projected) =~ secret
    assert [%{"signals" => %{"injection_score" => 1}}] = projected.data["guards"]
    refute Map.has_key?(projected.data["policy_evidence"], "settings")
  end

  test "a rolled back audit write publishes no notification" do
    scope = organization_fixture()
    Phoenix.PubSub.subscribe(AiControl.PubSub, "organizations:#{scope.organization.id}:dashboard")

    Phoenix.PubSub.subscribe(AiControl.PubSub, "organizations:#{scope.organization.id}:policies")
    Phoenix.PubSub.subscribe(AiControl.PubSub, "organizations:#{scope.organization.id}:access")

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               {:ok, _} = Audit.record_gateway(scope, Ecto.UUID.generate(), "completed", 1)

               {:ok, _} =
                 AiControl.Policies.create_version(
                   scope,
                   Configuration.default()
                 )

               Organizations.notify(scope.organization.id)
               {:ok, policy} = AiControl.Policies.current(scope)
               agent = AiControl.AgentsFixtures.agent_fixture(scope)
               principal = AiControl.GatewayFixtures.principal_fixture(scope, agent)

               {:ok, _} =
                 AiControl.Budgets.admit(
                   principal,
                   nil,
                   "qwen3.5:4b",
                   policy.snapshot,
                   Ecto.UUID.generate()
                 )

               Repo.rollback(:rollback)
             end)

    refute_received :dashboard_changed
    refute_received :policies_changed
    refute_received {:organization_access_changed, _}
    assert {:ok, _} = Audit.record_gateway(scope, Ecto.UUID.generate(), "completed", 1)
    assert_received :dashboard_changed
  end

  defp insert_copies(event, count) do
    attrs = event |> Map.from_struct() |> Map.drop([:__meta__, :id])

    Repo.insert_all(
      Event,
      Enum.map(1..count, fn _ ->
        Map.merge(attrs, %{
          id: Ecto.UUID.generate(),
          request_id: Ecto.UUID.generate(),
          target_id: Ecto.UUID.generate()
        })
      end),
      log: false
    )
  end
end
