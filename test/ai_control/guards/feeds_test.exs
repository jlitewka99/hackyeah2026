defmodule AiControl.Guards.FeedsTest do
  use AiControl.DataCase, async: false

  import AiControl.AgentsFixtures
  import AiControl.OrganizationsFixtures

  alias AiControl.Guards.{Feeds, Signatures}
  alias AiControl.Guards.Finding
  alias AiControl.{Policies, Repo}
  alias AiControl.Policies.{Configuration, Draft}

  setup do
    config = Application.get_env(:ai_control, Feeds)
    on_exit(fn -> Application.put_env(:ai_control, Feeds, config || []) end)
    :ok
  end

  test "packages are verified, immutable and activated only through tenant-owned v5 policies" do
    scope = organization_fixture()
    other = organization_fixture()
    agent = agent_fixture(scope)
    {:ok, original} = Policies.create_version(scope, Configuration.default(5))
    {:ok, inherited} = Policies.current(scope)
    {:ok, _} = Policies.activate(scope, original.id, inherited.set.revision)
    source = package()
    configure(source)
    {:ok, before} = Policies.current(scope)
    assert {:ok, set} = Feeds.import_package(scope, "operator.v1")
    assert {:ok, same} = Feeds.import_package(scope, "operator.v1")
    assert same.id == set.id
    assert {:ok, current} = Policies.current(scope)
    assert current.version.id == before.version.id
    policy = put_in(Configuration.default(5), ["detector_sets", "signatures"], set.set_id)
    assert {:error, _} = Policies.create_version(other, policy)
    assert {:ok, version} = Policies.create_version(scope, policy)
    assert {:ok, _} = Policies.activate(scope, version.id, current.set.revision)

    {:ok, {_key, token}} =
      AiControl.ApiKeys.create_key(scope, agent.id, %{label: "Synthetic feed test"})

    {:ok, principal} = AiControl.ApiKeys.authenticate(token)

    {:ok, selected, _} = Policies.snapshot_for_models(principal, nil)

    assert {:ok, result} =
             Signatures.assess(
               ["danger.literal"],
               %{organization_id: scope.organization.id},
               selected,
               []
             )

    assert result.detections != []
    assert {:ok, _} = Policies.rollback(scope, before.version.id, current.set.revision + 1)

    assert {:ok, result} =
             Signatures.assess(
               ["danger.literal"],
               %{organization_id: scope.organization.id},
               selected,
               []
             )

    assert result.detections != []
    assert {:error, :guard_unavailable} = Feeds.detectors(other.organization.id, set.set_id)

    assert_raise Postgrex.Error, fn ->
      Repo.update!(Ecto.Changeset.change(set, origin: "changed"))
    end
  end

  test "checksum mismatch, arbitrary regex, excessive literals and conflicting versions fail closed" do
    scope = organization_fixture()
    configure(package(), String.duplicate("0", 64))
    assert {:error, :invalid_feed} = Feeds.import_package(scope, "operator.v1")

    assert {:error, :invalid_feed} =
             Feeds.compile(
               put_in(package(), ["rules", "exploit.operator.v1", "matcher"], "regex")
             )

    assert {:error, :invalid_feed} =
             Feeds.compile(
               put_in(
                 package(),
                 ["rules", "exploit.operator.v1", "literal"],
                 String.duplicate("x", 257)
               )
             )

    configure(package())
    assert {:ok, set} = Feeds.import_package(scope, "operator.v1")
    configure(put_in(package(), ["rules", "exploit.operator.v1", "literal"], "different"))
    assert {:error, :invalid_feed} = Feeds.import_package(scope, "operator.v1")
    assert {:ok, [stored]} = Feeds.list(scope)
    assert stored.id == set.id
  end

  test "v1 through v4 normalization stays identical and imported selectors require v5" do
    for version <- 1..4 do
      source = Configuration.default(version)
      assert {:ok, original} = Configuration.validate(source)
      assert {:ok, roundtrip} = Configuration.validate(original.source)
      assert original == roundtrip
    end

    source =
      put_in(
        Configuration.default(4),
        ["detector_sets", "signatures"],
        "local." <> String.duplicate("a", 64)
      )

    assert {:error, _} = Configuration.validate(source)
    assert {:ok, _} = Configuration.validate(Map.put(source, "schema_version", 5))
  end

  test "dense imported literals cannot exhaust memory or silently truncate redaction" do
    assert {:ok, detectors} = Feeds.compile(package())

    assert {:ok, result} =
             Finding.scan_bounded(["danger.literal"], "signatures", "exploit", detectors)

    assert length(result.detections) == 1

    assert {:error, :guard_unavailable} =
             Finding.scan_bounded(
               [String.duplicate("danger.literal", 1025)],
               "signatures",
               "exploit",
               detectors
             )
  end

  test "v5 retains Knowledge and NER controls alongside an imported signature snapshot" do
    scope = organization_fixture()
    agent = agent_fixture(scope)
    configure(package())
    {:ok, set} = Feeds.import_package(scope, "operator.v1")

    source =
      Configuration.default(5)
      |> put_in(["detector_sets", "signatures"], set.set_id)
      |> Map.put("ner_model_set", "pl-nkjp.v1")
      |> Map.put("knowledge", %{
        "enabled" => true,
        "memory_write_enabled" => true,
        "sources" => ["memory"],
        "trust_levels" => ["internal"]
      })

    assert {:ok, config} =
             source |> Draft.from_source() |> Draft.source() |> Configuration.validate()

    assert config.settings["knowledge"] == source["knowledge"]
    assert config.settings["ner_model_set"] == "pl-nkjp.v1"
    assert config.settings["detector_sets"]["signatures"] == set.set_id
    assert {:ok, version} = Policies.create_version(scope, config.source)
    {:ok, current} = Policies.current(scope)
    assert {:ok, _} = Policies.activate(scope, version.id, current.set.revision)
    {:ok, {_key, token}} = AiControl.ApiKeys.create_key(scope, agent.id, %{label: "Synthetic v5"})
    {:ok, principal} = AiControl.ApiKeys.authenticate(token)
    assert {:ok, snapshot, _} = Policies.snapshot_for_models(principal, nil)
    assert snapshot.settings["knowledge"] == source["knowledge"]
    assert snapshot.settings["ner_model_set"] == "pl-nkjp.v1"

    assert {:ok, result} =
             Signatures.assess(
               ["danger.literal"],
               %{organization_id: scope.organization.id},
               snapshot,
               []
             )

    assert result.detections != []
  end

  defp package,
    do: %{
      "schema_version" => 1,
      "catalog_version" => "operator.v1",
      "origin" => "Local operator test",
      "rules" => %{
        "exploit.operator.v1" => %{
          "matcher" => "literal",
          "literal" => "danger.literal",
          "unsafe" => "Unsafe invocation",
          "safe_alternative" => "Safe invocation"
        }
      }
    }

  defp configure(source, expected \\ nil) do
    path = Path.join(System.tmp_dir!(), "feed-#{Ecto.UUID.generate()}.json")
    raw = Jason.encode!(source)
    File.write!(path, raw)
    on_exit(fn -> File.rm(path) end)
    checksum = expected || Base.encode16(:crypto.hash(:sha256, raw), case: :lower)

    Application.put_env(:ai_control, Feeds,
      packages: %{"operator.v1" => %{"path" => path, "sha256" => checksum}}
    )
  end
end
