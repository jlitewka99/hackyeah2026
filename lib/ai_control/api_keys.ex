defmodule AiControl.ApiKeys do
  @moduledoc "One-time API secrets, transactional rotation, and database-backed agent authentication."
  import Ecto.Query

  alias AiControl.Agents
  alias AiControl.ApiKeys.{ApiKey, Principal}
  alias AiControl.Organizations
  alias AiControl.Organizations.Access
  alias AiControl.Repo

  def change_key(attrs \\ %{}), do: ApiKey.changeset(%ApiKey{}, attrs)

  def list_keys(scope, agent_id \\ nil) do
    with {:ok, current} <- Access.authorize(scope, "api_keys.read"),
         {:ok, agent_id} <- filter_agent(current, agent_id) do
      query =
        from(k in ApiKey,
          where: k.organization_id == ^current.organization.id,
          order_by: [desc: k.inserted_at, desc: k.id],
          preload: [:agent]
        )

      query =
        if "*" in current.grants.agents,
          do: query,
          else: from(k in query, where: k.agent_id in ^current.grants.agents)

      query = if agent_id, do: from(k in query, where: k.agent_id == ^agent_id), else: query
      {:ok, Enum.map(Repo.all(query), &metadata/1)}
    end
  end

  def create_key(scope, agent_id, attrs) do
    Organizations.locked(scope, fn current ->
      with {:ok, agent} <- active_agent(current, agent_id) do
        insert_key(current, agent, attrs)
      end
    end)
  end

  def revoke_key(scope, id) do
    Organizations.locked(scope, fn current ->
      with {:ok, key} <- managed_key(current, id),
           {:ok, key} <- revoke(key) do
        {:ok, metadata(key)}
      end
    end)
  end

  def rotate_key(scope, id, attrs \\ %{}) do
    Organizations.locked(scope, fn current ->
      with {:ok, key} <- managed_key(current, id),
           true <- active?(key),
           {:ok, agent} <- active_agent(current, key.agent_id),
           attrs = replacement_attrs(attrs, key.label),
           {:ok, replacement} <- insert_key(current, agent, attrs),
           {:ok, _} <- revoke(key) do
        {:ok, replacement}
      else
        false -> {:error, :inactive_key}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp replacement_attrs(attrs, label) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put_new("label", label)
  end

  @doc "Returns only a principal; every call rechecks key, agent, and organization state."
  def authenticate(token) when is_binary(token) and byte_size(token) == 84 do
    with ["aic", id, secret] <- String.split(token, "_", parts: 3),
         {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, decoded} <- Base.url_decode64(secret, padding: false),
         true <- byte_size(decoded) == 32 do
      hash = :crypto.hash(:sha256, token)
      now = DateTime.utc_now()

      query =
        from(k in ApiKey,
          join: a in assoc(k, :agent),
          join: o in assoc(k, :organization),
          where: k.id == ^id and k.token_hash == ^hash and is_nil(k.revoked_at),
          where: is_nil(k.expires_at) or k.expires_at > ^now,
          where: a.organization_id == o.id and a.status == :active and o.status == :active,
          select: %Principal{organization_id: o.id, agent_id: a.id, api_key_id: k.id}
        )

      case Repo.one(query, log: false) do
        %Principal{} = principal -> {:ok, principal}
        _ -> {:error, :invalid_api_key}
      end
    else
      _ -> {:error, :invalid_api_key}
    end
  end

  def authenticate(_), do: {:error, :invalid_api_key}
  def status(%{revoked_at: at}) when not is_nil(at), do: :revoked
  def status(key), do: if(active?(key), do: :active, else: :expired)

  defp active?(key),
    do:
      is_nil(key.revoked_at) &&
        (is_nil(key.expires_at) || DateTime.after?(key.expires_at, DateTime.utc_now()))

  defp insert_key(current, agent, attrs) do
    id = Ecto.UUID.generate()
    token = "aic_#{id}_#{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}"

    key = %ApiKey{
      id: id,
      organization_id: current.organization.id,
      agent_id: agent.id,
      prefix: "aic_#{String.slice(id, 0, 8)}",
      token_hash: :crypto.hash(:sha256, token)
    }

    with {:ok, key} <- Repo.insert(ApiKey.changeset(key, attrs), log: false) do
      {:ok, {metadata(%{key | agent: agent}), token}}
    end
  end

  defp active_agent(scope, id) do
    with {:ok, agent} <- Agents.fetch_agent(scope, id, "api_keys.manage"),
         true <- scope.organization.status == :active and agent.status == :active do
      {:ok, agent}
    else
      false -> {:error, :inactive_agent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp managed_key(scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %ApiKey{} = key <- Repo.get_by(ApiKey, id: id, organization_id: scope.organization.id),
         {:ok, _} <- Access.authorize(scope, "api_keys.manage", %{agent: key.agent_id}) do
      {:ok, Repo.preload(key, :agent)}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp revoke(%ApiKey{revoked_at: nil} = key),
    do: Repo.update(Ecto.Changeset.change(key, revoked_at: DateTime.utc_now(:second)))

  defp revoke(key), do: {:ok, key}

  defp filter_agent(_, id) when id in [nil, ""], do: {:ok, nil}

  defp filter_agent(scope, id) do
    with {:ok, agent} <- Agents.fetch_agent(scope, id, "api_keys.read"), do: {:ok, agent.id}
  end

  defp metadata(key) do
    key
    |> Map.take([
      :id,
      :label,
      :organization_id,
      :agent_id,
      :prefix,
      :expires_at,
      :revoked_at,
      :inserted_at,
      :updated_at
    ])
    |> Map.merge(%{agent_name: key.agent.name, agent_status: key.agent.status})
  end
end
