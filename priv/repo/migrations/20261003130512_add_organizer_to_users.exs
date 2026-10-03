defmodule AiControl.Repo.Migrations.AddOrganizerToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :organizer, :boolean, null: false, default: false
    end

    create unique_index(:users, [:organizer],
             where: "organizer = true",
             name: :users_single_organizer_index
           )
  end
end
