defmodule AiControl.Audit.Filters do
  @moduledoc "One validated filter contract for the audit page, metrics and export. All dates are UTC."
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias AiControl.Audit.Event
  alias AiControl.Policies.Configuration

  @primary_key false
  embedded_schema do
    field :range, :string, default: "24h"
    field :from, :utc_datetime_usec
    field :to, :utc_datetime_usec
    field :kind, Ecto.Enum, values: [:decision, :gateway, :administrative]
    field :action, Ecto.Enum, values: [:allow, :redact, :block, :review]
    field :stage, Ecto.Enum, values: [:input, :output, :administrative]
    field :guard, :string
    field :agent_id, :binary_id
    field :reason_code, :string
    field :request_id, :binary_id
    field :run_id, :binary_id
    field :cursor, :string
  end

  def parse(params \\ %{}, now \\ DateTime.utc_now()) do
    changeset =
      %__MODULE__{}
      |> cast(
        normalize_dates(params),
        ~w(range from to kind action stage guard agent_id reason_code request_id run_id cursor)a
      )
      |> validate_inclusion(:range, ~w(1h 24h 7d custom))
      |> validate_inclusion(:guard, Configuration.guards(6))
      |> validate_format(:reason_code, ~r/\A[a-z][a-z0-9_.-]{0,95}\z/)
      |> validate_change(:agent_id, &uuid/2)
      |> validate_change(:request_id, &uuid/2)
      |> validate_change(:run_id, &uuid/2)
      |> validate_change(:cursor, fn :cursor, value ->
        if match?({:ok, _}, decode_cursor(value)), do: [], else: [cursor: "is invalid"]
      end)
      |> time_range(now)

    apply_action(changeset, :validate)
  end

  def query(organization_id, filters) do
    base =
      from(e in Event,
        where:
          e.organization_id == ^organization_id and e.occurred_at >= ^filters.from and
            e.occurred_at < ^filters.to
      )

    Enum.reduce([:kind, :action, :stage, :agent_id, :request_id, :run_id], base, fn key, query ->
      case Map.get(filters, key) do
        nil -> query
        value -> from(e in query, where: field(e, ^key) == ^value)
      end
    end)
    |> reason(filters.reason_code)
    |> guard(filters.guard)
  end

  def cursor(nil), do: nil

  def cursor(event),
    do:
      Base.url_encode64(Jason.encode!([DateTime.to_iso8601(event.occurred_at), event.id]),
        padding: false
      )

  def after_cursor(query, nil), do: query

  def after_cursor(query, cursor) do
    {:ok, {time, id}} = decode_cursor(cursor)
    from(e in query, where: e.occurred_at < ^time or (e.occurred_at == ^time and e.id < ^id))
  end

  def params(filters) do
    filters
    |> Map.from_struct()
    |> Map.take(~w(range from to kind action stage guard agent_id reason_code request_id run_id)a)
    |> Enum.reject(fn {_, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} ->
      value =
        if match?(%DateTime{}, value), do: DateTime.to_iso8601(value), else: to_string(value)

      {Atom.to_string(key), value}
    end)
  end

  defp decode_cursor(value) when is_binary(value) and byte_size(value) <= 256 do
    with {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok, [time, id]} <- Jason.decode(json),
         true <- is_binary(time) && is_binary(id),
         {:ok, time, 0} <- DateTime.from_iso8601(time),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {time, id}}
    else
      _ -> :error
    end
  end

  defp decode_cursor(_), do: :error

  defp uuid(key, value),
    do: if(match?({:ok, _}, Ecto.UUID.cast(value)), do: [], else: [{key, "must be a UUID"}])

  defp reason(query, nil), do: query
  defp reason(query, code), do: from(e in query, where: ^code in e.reason_codes)
  defp guard(query, nil), do: query

  defp guard(query, name),
    do:
      from(e in query,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(?->'guards', '[]'::jsonb)) g WHERE g->>'guard' = ?)",
            e.data,
            ^name
          )
      )

  defp normalize_dates(params) do
    Map.new(params, fn {key, value} ->
      value =
        if key in ["from", "to"] && is_binary(value) && value != "" &&
             !String.ends_with?(value, "Z") && !String.contains?(value, "+"),
           do: utc_input(value),
           else: value

      {key, value}
    end)
  end

  defp utc_input(value), do: value <> if(String.length(value) == 16, do: ":00Z", else: "Z")

  defp time_range(changeset, now) do
    changeset =
      case get_field(changeset, :range) do
        "custom" ->
          validate_required(changeset, [:from, :to])

        range when range in ~w(1h 24h 7d) ->
          seconds = %{"1h" => 3600, "24h" => 86_400, "7d" => 604_800}[range]
          changeset |> put_change(:from, DateTime.add(now, -seconds)) |> put_change(:to, now)

        _ ->
          changeset
      end

    case {get_field(changeset, :from), get_field(changeset, :to)} do
      {%DateTime{} = first, %DateTime{} = last} ->
        if DateTime.before?(first, last),
          do: changeset,
          else: add_error(changeset, :to, "must be after the start")

      _ ->
        changeset
    end
  end
end
