defmodule AiControl.OrganizationNamesTest do
  use AiControl.DataCase, async: true

  import AiControl.OrganizationsFixtures

  alias AiControl.Organizations

  test "names are unique regardless of case or surrounding spaces" do
    organizer = organizer_scope_fixture()
    assert {:ok, organization} = Organizations.create_organization(organizer, %{name: "Acme"})

    for name <- ["Acme", "acme", "ACME", "  Acme  "] do
      assert {:error, changeset} = Organizations.create_organization(organizer, %{name: name})
      assert errors_on(changeset).name == ["An organization with this name already exists."]
    end

    assert {:ok, _} = Organizations.create_organization(organizer, %{name: "Acme Labs"})
    assert organization.name == "Acme"
  end

  test "a suspended organization's name remains reserved" do
    organization = organization_fixture(%{name: "Reserved"})
    assert {:ok, _} = Organizations.set_status(organization, :suspended)

    assert {:error, changeset} =
             Organizations.create_organization(organization, %{name: "reserved"})

    assert errors_on(changeset).name == ["An organization with this name already exists."]
  end
end
