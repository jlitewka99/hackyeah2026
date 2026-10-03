defmodule AiControl.OrganizationNameMigrationTest do
  use AiControl.DataCase, async: false

  alias AiControl.Organizations.Organization
  alias AiControl.Repo.Migrations.EnsureUniqueOrganizationNames
  alias Ecto.Migration.Runner

  if !Code.ensure_loaded?(EnsureUniqueOrganizationNames) do
    Code.require_file(
      "../../priv/repo/migrations/20261003164931_ensure_unique_organization_names.exs",
      __DIR__
    )
  end

  @version 20_261_003_164_931

  test "migration preserves the oldest organization and skips occupied suffixes" do
    migrate(:forward, :down)
    oldest = insert_organization("test-org", 0)
    second = insert_organization("  TEST-ORG  ", 1)
    third = insert_organization("test-org", 2)
    occupied = insert_organization("TEST-ORG (2)", 3)

    migrate(:forward, :up)

    assert Repo.get!(Organization, oldest.id).name == "test-org"
    assert Repo.get!(Organization, second.id).name == "TEST-ORG (3)"
    assert Repo.get!(Organization, third.id).name == "test-org (4)"
    assert Repo.get!(Organization, occupied.id).name == "TEST-ORG (2)"

    migrate(:forward, :down)
    assert Repo.get!(Organization, second.id).name == "TEST-ORG (3)"
  end

  test "renamed 120-character names fit the limit and remain distinct" do
    migrate(:forward, :down)
    name = String.duplicate("a", 120)
    oldest = insert_organization(name, 0)
    second = insert_organization(String.upcase(name), 1)
    occupied = insert_organization(String.duplicate("a", 116) <> " (2)", 2)

    migrate(:forward, :up)

    assert Repo.get!(Organization, oldest.id).name == name
    renamed = Repo.get!(Organization, second.id)
    assert String.length(renamed.name) == 120
    assert renamed.name == String.duplicate("A", 116) <> " (3)"
    assert Repo.get!(Organization, occupied.id).name == String.duplicate("a", 116) <> " (2)"
  end

  defp insert_organization(name, seconds) do
    Repo.insert!(%Organization{
      name: name,
      inserted_at: DateTime.add(~U[2026-01-01 00:00:00Z], seconds),
      updated_at: ~U[2026-01-01 00:00:00Z]
    })
  end

  defp migrate(direction, operation) do
    Runner.run(
      Repo,
      Repo.config(),
      @version,
      EnsureUniqueOrganizationNames,
      direction,
      operation,
      operation,
      log: false,
      log_migrations_sql: false
    )
  end
end
