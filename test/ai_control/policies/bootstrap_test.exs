defmodule AiControl.Policies.BootstrapTest do
  use AiControl.DataCase, async: false

  alias AiControl.{OrganizationsFixtures, Repo}
  alias AiControl.Policies.{Activation, Bootstrap, Configuration, ConfigurationV2, Set, Version}
  alias AiControl.Policy.Snapshot

  test "fresh installation appends and activates DeepSeek without changing history" do
    set = Repo.one!(from(s in Set, where: is_nil(s.organization_id)))
    old = Repo.get!(Version, set.active_version_id)
    count = Repo.aggregate(Version, :count)
    assert {:ok, :ok} = Bootstrap.seed_new_installation(Repo)
    current = Repo.get!(Set, set.id)
    version = Repo.get!(Version, current.active_version_id)
    assert current.revision == 2
    assert version.configuration["allowed_models"] == ["deepseek-flash"]
    assert Repo.get!(Version, old.id) == old
    assert Repo.aggregate(Version, :count) == count + 1
    assert {:ok, snapshot} = Snapshot.from_version(version)
    assert snapshot.checksum == version.checksum
    activation = Repo.get_by!(Activation, set_id: set.id, revision: 2)
    assert activation.previous_version_id == old.id
    assert {:ok, :ok} = Bootstrap.seed_new_installation(Repo)
    assert Repo.get!(Set, set.id) == current
    assert Repo.aggregate(Version, :count) == count + 1
  end

  test "existing organization keeps its inherited historical policy" do
    _ = OrganizationsFixtures.organization_fixture()
    set = Repo.one!(from(s in Set, where: is_nil(s.organization_id)))
    assert {:ok, :ok} = Bootstrap.seed_new_installation(Repo)
    assert Repo.get!(Set, set.id) == set
  end

  test "new authoring defaults change without rewriting frozen normalization" do
    assert Configuration.default()["allowed_models"] == ["deepseek-flash"]
    assert ConfigurationV2.default()["allowed_models"] == ["qwen3.5:4b"]

    assert Configuration.validate(ConfigurationV2.default()) ==
             ConfigurationV2.validate(ConfigurationV2.default())
  end
end
