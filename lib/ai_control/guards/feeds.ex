defmodule AiControl.Guards.Feeds do
  @moduledoc "Local operator packages become immutable tenant catalogs; importing never activates a policy."
  import Ecto.Query

  alias AiControl.Guards.{FeedSet, Registry, Signatures}
  alias AiControl.Organizations
  alias AiControl.Repo
  alias AiControl.Security.Validation
  alias Organizations.Access

  def packages,
    do: Application.get_env(:ai_control, __MODULE__, []) |> Keyword.get(:packages, %{})

  def package_ids, do: packages() |> Map.keys() |> Enum.sort()

  def import_package(scope, id) do
    with {:ok, current} <- Access.authorize(scope, "signatures.manage"),
         %{"path" => path, "sha256" => expected} <- Map.get(packages(), id),
         true <- Validation.checksum?(expected),
         {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= 1_048_576,
         {:ok, raw} <- File.read(path),
         true <- hash(raw) == expected,
         {:ok, source} <- Jason.decode(raw),
         {:ok, _} <- compile(source),
         {:ok, current} <- Access.authorize(current, "signatures.manage") do
      attrs = %{
        organization_id: current.organization.id,
        set_id: "local." <> expected,
        checksum: expected,
        version: source["catalog_version"],
        origin: source["origin"],
        rules: source["rules"],
        inserted_at: DateTime.utc_now()
      }

      publish(current, attrs)
    else
      _ -> {:error, :invalid_feed}
    end
  rescue
    _ -> {:error, :invalid_feed}
  end

  defp publish(scope, attrs) do
    Organizations.locked(scope, fn current -> publish_locked(current, attrs) end)
  end

  defp publish_locked(current, attrs) do
    with {:ok, _} <- Access.authorize(current, "signatures.manage"),
         true <- current.organization.status == :active do
      case Repo.get_by(FeedSet,
             organization_id: current.organization.id,
             version: attrs.version
           ) do
        nil ->
          Repo.insert_all(FeedSet, [Map.put(attrs, :id, Ecto.UUID.generate())], log: false)

          {:ok,
           Repo.get_by!(FeedSet, organization_id: current.organization.id, set_id: attrs.set_id)}

        %{checksum: checksum} = set when checksum == attrs.checksum ->
          {:ok, set}

        _ ->
          {:error, :invalid_feed}
      end
    else
      _ -> {:error, :invalid_feed}
    end
  end

  def list(scope) do
    with {:ok, current} <- Access.authorize(scope, "signatures.read") do
      {:ok,
       Repo.all(
         from(s in FeedSet,
           where: s.organization_id == ^current.organization.id,
           order_by: [desc: s.inserted_at]
         ),
         log: false
       )}
    end
  end

  def selectors(scope) do
    case Access.authorize(scope, "policies.read") do
      {:ok, current} ->
        Repo.all(
          from(s in FeedSet,
            where: s.organization_id == ^current.organization.id,
            order_by: s.version,
            select: {s.version, s.set_id}
          ),
          log: false
        )

      _ ->
        []
    end
  end

  def owned?(_, "builtin.v1"), do: true

  def owned?(org, set),
    do:
      Repo.exists?(from(s in FeedSet, where: s.organization_id == ^org and s.set_id == ^set),
        log: false
      )

  def catalog(_, "builtin.v1"), do: {:ok, Registry.catalog()}

  def catalog(org, set) do
    case Repo.get_by(FeedSet, organization_id: org, set_id: set) do
      nil ->
        {:error, :guard_unavailable}

      source ->
        {:ok,
         %{
           version: source.version,
           origin: source.origin,
           checksum: source.checksum,
           rules:
             Map.new(source.rules, fn {id, rule} ->
               {id, %{unsafe: rule["unsafe"], safe_alternative: rule["safe_alternative"]}}
             end)
         }}
    end
  end

  def detectors(_, "builtin.v1"), do: {:ok, Signatures.builtin_detectors()}

  def detectors(org, set) do
    with %FeedSet{} = value <- Repo.get_by(FeedSet, organization_id: org, set_id: set),
         {:ok, detectors} <-
           compile(%{
             "schema_version" => 1,
             "catalog_version" => value.version,
             "origin" => value.origin,
             "rules" => value.rules
           }) do
      {:ok, detectors}
    else
      _ -> {:error, :guard_unavailable}
    end
  end

  def compile(source) do
    with true <-
           is_map(source) &&
             Enum.sort(Map.keys(source)) ==
               Enum.sort(~w(schema_version catalog_version origin rules)),
         true <- source["schema_version"] == 1 && Validation.code?(source["catalog_version"]),
         true <- text?(source["origin"], 256),
         rules when is_map(rules) and map_size(rules) in 1..256 <- source["rules"],
         true <- Enum.all?(rules, &rule?/1) do
      {:ok, rules |> Enum.sort() |> Enum.map(&compile_rule/1)}
    else
      _ -> {:error, :invalid_feed}
    end
  rescue
    _ -> {:error, :invalid_feed}
  end

  def selector?("builtin.v1"), do: true
  def selector?("local." <> checksum), do: Validation.checksum?(checksum)
  def selector?(_), do: false
  defp hash(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp text?(value, max),
    do:
      is_binary(value) && String.valid?(value) && byte_size(value) in 1..max &&
        !String.contains?(value, <<0>>)

  defp rule?({id, rule}) when is_map(rule) do
    Validation.code?(id) && String.starts_with?(id, "exploit.") &&
      Enum.all?(Map.keys(rule), &(&1 in ~w(matcher literal unsafe safe_alternative))) &&
      rule["matcher"] in ~w(pickle yaml eval shell literal) &&
      text?(rule["unsafe"], 256) && text?(rule["safe_alternative"], 256) &&
      if(rule["matcher"] == "literal",
        do: text?(rule["literal"], 256),
        else: !Map.has_key?(rule, "literal")
      )
  end

  defp rule?(_), do: false

  defp compile_rule({id, %{"matcher" => "literal", "literal" => literal}}),
    do: {id, Regex.compile!(Regex.escape(literal)), fn _, _, _ -> true end}

  defp compile_rule({id, rule}) do
    {_, pattern, validator} =
      Enum.find(Signatures.builtin_detectors(), fn {key, _, _} ->
        key == "exploit.#{rule["matcher"]}.v1"
      end)

    {id, pattern, validator}
  end
end
