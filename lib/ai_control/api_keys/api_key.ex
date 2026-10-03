defmodule AiControl.ApiKeys.ApiKey do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_keys" do
    field :label, :string
    field :token_hash, :binary, redact: true
    field :prefix, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    field :expiry_mode, Ecto.Enum,
      values: [:ninety_days, :custom, :never],
      virtual: true,
      default: :ninety_days

    field :expiry_at, :naive_datetime, virtual: true
    belongs_to :organization, AiControl.Organizations.Organization
    belongs_to :agent, AiControl.Agents.Agent
    timestamps(type: :utc_datetime)
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:label, :expiry_mode, :expiry_at])
    |> update_change(:label, &String.trim/1)
    |> validate_required([:label, :expiry_mode])
    |> validate_length(:label, min: 2, max: 120)
    |> set_expiration()
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint(:token_hash)
  end

  defp set_expiration(changeset) do
    case get_field(changeset, :expiry_mode) do
      :ninety_days ->
        put_change(changeset, :expires_at, DateTime.add(DateTime.utc_now(:second), 90, :day))

      :never ->
        put_change(changeset, :expires_at, nil)

      :custom ->
        custom_expiration(changeset)

      _ ->
        changeset
    end
  end

  defp custom_expiration(changeset) do
    case get_field(changeset, :expiry_at) do
      %NaiveDateTime{} = at ->
        at = at |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)

        if DateTime.after?(at, DateTime.utc_now()),
          do: put_change(changeset, :expires_at, at),
          else: add_error(changeset, :expiry_at, "must be in the future (UTC)")

      _ ->
        add_error(changeset, :expiry_at, "choose a future date and time (UTC)")
    end
  end
end
