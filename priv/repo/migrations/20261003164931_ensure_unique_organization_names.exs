defmodule AiControl.Repo.Migrations.EnsureUniqueOrganizationNames do
  use Ecto.Migration

  def up do
    execute("LOCK TABLE organizations IN SHARE ROW EXCLUSIVE MODE")

    execute("""
    DO $$
    DECLARE
      duplicate record;
      candidate text;
      suffix text;
      counter bigint;
    BEGIN
      FOR duplicate IN
        SELECT id, name FROM (
          SELECT id, name, inserted_at,
            row_number() OVER (
              PARTITION BY lower(btrim(name)) ORDER BY inserted_at, id
            ) AS position
          FROM organizations
        ) ranked
        WHERE position > 1
        ORDER BY inserted_at, id
      LOOP
        counter := 2;
        LOOP
          suffix := ' (' || counter || ')';
          candidate := left(btrim(duplicate.name), 120 - char_length(suffix)) || suffix;
          EXIT WHEN NOT EXISTS (
            SELECT 1 FROM organizations WHERE lower(btrim(name)) = lower(candidate)
          );
          counter := counter + 1;
        END LOOP;

        UPDATE organizations
        SET name = candidate, updated_at = date_trunc('second', now() AT TIME ZONE 'UTC')
        WHERE id = duplicate.id;
      END LOOP;
    END $$;
    """)

    create unique_index(:organizations, ["lower(btrim(name))"],
             name: :organizations_name_unique_index
           )
  end

  def down do
    drop index(:organizations, ["lower(btrim(name))"], name: :organizations_name_unique_index)
  end
end
