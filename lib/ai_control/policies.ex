defmodule AiControl.Policies do
  @moduledoc "Authoritative versioned policies with explicit activation and global inheritance."
  import Ecto.Query

  alias AiControl.Accounts.{Scope, User}
  alias AiControl.Agents.Agent
  alias AiControl.ApiKeys.{ApiKey, Principal}
  alias AiControl.{Audit, Repo}
  alias AiControl.Organizations.{Access, Organization, ResourceResolver}
  alias AiControl.Organizations.Grants
  alias AiControl.Policies.{Activation, Cache, Configuration, Set, Version, YAML}
  alias AiControl.Policy.Snapshot

  def validate(source), do: Configuration.validate(source)
  def import_yaml(text), do: YAML.decode(text)

  def current(scope, target \\ :organization) do
    with {:ok, current} <- authorize(scope, "policies.read", target),
         %Set{} = set <- set_for(current, target),
         {:ok, version, inherited?} <- effective_version(set),
         {:ok, snapshot} <- snapshot(version) do
      {:ok, %{set: set, version: version, snapshot: snapshot, inherited?: inherited?}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :policy_unavailable}
    end
  end

  @doc "Capability-specific effective settings; never exposes the complete policy to a reporting reader."
  def summary(scope, section) when section in [:budgets, :signatures] do
    permission = if section == :budgets, do: "budgets.read", else: "signatures.read"

    with {:ok, current} <- Access.authorize(scope, permission),
         %Set{} = set <- set_for(current, :organization),
         {:ok, version, inherited?} <- effective_version(set) do
      settings = version.settings

      data =
        if section == :budgets,
          do: %{limits: settings["budgets"]},
          else: %{
            guard: settings["guards"]["signatures"],
            rule: settings["rules"]["exploit"],
            set: settings["detector_sets"]["signatures"]
          }

      {:ok,
       Map.merge(data, %{
         version: "policy-#{version.id}",
         checksum: version.checksum,
         inherited?: inherited?
       })}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :policy_unavailable}
    end
  end

  def list_versions(scope, target \\ :organization) do
    with {:ok, current} <- authorize(scope, "policies.read", target),
         %Set{} = set <- set_for(current, target) do
      {:ok,
       Repo.all(
         from(v in Version,
           where: v.set_id == ^set.id,
           order_by: [desc: v.inserted_at, desc: v.id]
         ),
         log: false
       )}
    else
      _ -> {:error, :forbidden}
    end
  end

  def get_version(scope, id, target \\ :organization) do
    with {:ok, current} <- authorize(scope, "policies.read", target),
         {:ok, id} <- Ecto.UUID.cast(id),
         %Set{} = set <- set_for(current, target),
         %Version{} = version <- Repo.get_by(Version, [id: id, set_id: set.id], log: false) do
      {:ok, version}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      _ -> {:error, :not_found}
    end
  end

  def export_yaml(scope, id, target \\ :organization) do
    with {:ok, version} <- get_version(scope, id, target),
         do: {:ok, YAML.encode(version.configuration)}
  end

  def create_version(scope, source, target \\ :organization) do
    mutate(scope, target, fn current, set ->
      with {:ok, config} <- Configuration.validate(source),
           :ok <- ownership(config.source, current, target),
           version = %Version{
             id: Ecto.UUID.generate(),
             set_id: set.id,
             author_id: current.user.id,
             configuration: config.source,
             settings: config.settings,
             inserted_at: DateTime.utc_now()
           },
           {:ok, snapshot} <- Snapshot.from_version(version),
           {:ok, version} <- Repo.insert(%{version | checksum: snapshot.checksum}, log: false),
           {:ok, _} <-
             policy_audit(current, target, "policy.version_created", version.id, nil, version) do
        {:ok, version}
      end
    end)
  end

  def activate(scope, id, revision, target \\ :organization),
    do: switch(scope, id, revision, target, "activate")

  def rollback(scope, id, revision, target \\ :organization),
    do: switch(scope, id, revision, target, "rollback")

  def inherit(scope, revision), do: switch(scope, nil, revision, :organization, "inherit")

  defp switch(scope, id, revision, target, operation) do
    mutate(scope, target, &switch_locked(&1, &2, id, revision, target, operation))
  end

  defp switch_locked(current, set, id, revision, target, operation) do
    with true <- is_integer(revision) && revision == set.revision,
         {:ok, version} <- candidate(set, id, operation),
         :ok <- candidate_owned(version, current, target),
         previous =
           if(set.active_version_id, do: Repo.get!(Version, set.active_version_id, log: false)),
         {:ok, _} <-
           Repo.update(
             Ecto.Changeset.change(set, active_version_id: id, revision: set.revision + 1),
             log: false
           ),
         {:ok, activation} <-
           Repo.insert(
             %Activation{
               set_id: set.id,
               version_id: id,
               previous_version_id: set.active_version_id,
               author_id: current.user.id,
               operation: operation,
               revision: set.revision + 1,
               inserted_at: DateTime.utc_now()
             },
             log: false
           ),
         event = event_type(operation),
         {:ok, _} <- policy_audit(current, target, event, activation.id, previous, version) do
      {:ok, activation}
    else
      false -> {:error, :stale_policy}
      error -> error
    end
  end

  defp candidate(_set, nil, "inherit"), do: {:ok, nil}

  defp candidate(set, id, operation) when operation in ["activate", "rollback"] do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Version{} = version <- Repo.get_by(Version, [id: id, set_id: set.id], log: false),
         true <-
           operation != "rollback" ||
             Repo.exists?(
               from(a in Activation, where: a.set_id == ^set.id and a.version_id == ^id)
             ) do
      {:ok, version}
    else
      _ -> {:error, :not_found}
    end
  end

  defp candidate(_, _, _), do: {:error, :not_found}
  defp candidate_owned(nil, _, _), do: :ok

  defp candidate_owned(version, scope, target),
    do: ownership(version.configuration, scope, target)

  defp mutate(scope, target, callback) do
    result =
      Repo.transact(fn ->
        lock_organization(scope, target)

        with {:ok, current} <- authorize(scope, "policies.manage", target),
             %Set{} = set <- set_for(current, target, "FOR UPDATE") do
          callback.(current, set)
        else
          _ -> {:error, :forbidden}
        end
      end)

    if match?({:ok, _}, result) && !Repo.in_transaction?() do
      {_status, record} = result
      warm(record)
      Phoenix.PubSub.broadcast(AiControl.PubSub, topic(scope, target), :policies_changed)
      if target == :organization, do: Audit.notify(scope.organization.id)
    end

    result
  end

  defp lock_organization(%Scope{organization: %{id: id}}, :organization),
    do: Repo.one(from(o in Organization, where: o.id == ^id, lock: "FOR UPDATE"), log: false)

  defp lock_organization(_, _), do: nil

  defp authorize(%Scope{user: %{id: id}} = scope, _permission, :global) do
    case Repo.get(User, id, log: false) do
      %User{organizer: true} = user -> {:ok, %{scope | user: user}}
      _ -> {:error, :forbidden}
    end
  end

  defp authorize(scope, permission, :organization), do: Access.authorize(scope, permission)
  defp authorize(_, _, _), do: {:error, :forbidden}

  defp set_for(scope, target, lock \\ nil) do
    query =
      case target do
        :global -> from(s in Set, where: is_nil(s.organization_id))
        :organization -> from(s in Set, where: s.organization_id == ^scope.organization.id)
      end

    Repo.one(if(lock, do: from(s in query, lock: "FOR UPDATE"), else: query), log: false)
  end

  defp effective_version(%Set{id: id}) do
    query =
      from(local in Set,
        join: global in Set,
        on: is_nil(global.organization_id),
        join: v in Version,
        on: v.id == fragment("COALESCE(?, ?)", local.active_version_id, global.active_version_id),
        where: local.id == ^id,
        select: {v, is_nil(local.active_version_id)}
      )

    case Repo.one(query, log: false) do
      {version, inherited?} -> {:ok, version, inherited?}
      _ -> {:error, :policy_unavailable}
    end
  end

  defp snapshot(version) do
    case Cache.fetch(version.id) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      :miss ->
        with {:ok, snapshot} <- Snapshot.from_version(version) do
          Cache.put(version.id, snapshot)
          {:ok, snapshot}
        end
    end
  end

  defp warm(%Version{} = version), do: snapshot(version)
  defp warm(%Activation{version_id: nil}), do: :ok
  defp warm(%Activation{version_id: id}), do: warm(Repo.get!(Version, id, log: false))

  def topic(_scope, :global), do: "platform:policies"
  def topic(scope, :organization), do: "organizations:#{scope.organization.id}:policies"

  defp ownership(source, _scope, :global) do
    if source["allowed_agents"] in [[], ["*"]] && map_size(source["agent_models"]) == 0,
      do: :ok,
      else: {:error, [{"allowed_agents", "global policies use a wildcard or an empty list"}]}
  end

  defp ownership(source, scope, :organization) do
    agents = (source["allowed_agents"] -- ["*"]) ++ Map.keys(source["agent_models"])

    if Enum.all?(agents, &AiControl.Agents.owned?(scope.organization.id, &1)),
      do: :ok,
      else: {:error, [{"allowed_agents", "every agent must belong to this organization"}]}
  end

  defp policy_audit(scope, target, event, id, before, after_version) do
    attrs = %{target_id: id, before: evidence(before), after: evidence(after_version)}

    case target do
      :global -> Audit.record_platform(scope, event, attrs)
      :organization -> Audit.record_admin(scope, event, attrs)
    end
  end

  defp evidence(nil) do
    version =
      Repo.one!(
        from(v in Version,
          join: s in Set,
          on: s.active_version_id == v.id,
          where: is_nil(s.organization_id)
        ),
        log: false
      )

    version |> evidence() |> Map.put(:policy_source, "global")
  end

  defp evidence(version),
    do: %{
      policy_version_id: version.id,
      policy_checksum: version.checksum,
      policy_profile: version.settings["profile"]
    }

  defp event_type("rollback"), do: "policy.rolled_back"
  defp event_type("inherit"), do: "policy.inheritance_restored"
  defp event_type(_), do: "policy.activated"

  @doc "Acquire once per request and retain this immutable snapshot at every stage."
  def snapshot_for_request(identity, resources) do
    with {:ok, current} <- request_authorization(identity, resources),
         {:ok, policy, current} <- snapshot_for_models(current, Map.get(resources, :agent_id)),
         :ok <- model_access(current, policy, Map.get(resources, :agent_id), resources[:model]) do
      {:ok, policy}
    end
  end

  defp request_authorization(%Scope{} = scope, %{agent_id: agent, model: model}),
    do: Access.authorize(scope, "ai.use", %{agent: agent, model: model})

  defp request_authorization(%Principal{} = principal, resources) when is_map(resources),
    do: refresh_identity(principal)

  defp request_authorization(_, _), do: {:error, :forbidden}

  def refresh_identity(%Principal{} = principal) do
    if principal_valid?(principal), do: {:ok, principal}, else: {:error, :forbidden}
  end

  def refresh_identity(%Scope{} = scope) do
    with {:ok, current} <- AiControl.Organizations.refresh_scope(scope),
         true <- current.organization.status == :active && "ai.use" in current.grants.permissions do
      {:ok, current}
    else
      _ -> {:error, :forbidden}
    end
  end

  def refresh_identity(_), do: {:error, :forbidden}

  @doc "One snapshot for a filtered catalog, without loading a new policy for each candidate."
  def snapshot_for_models(identity, agent_id) do
    with {:ok, current} <- refresh_identity(identity),
         {:ok, organization_id, agent} <- catalog_identity(current, agent_id),
         %Set{} = set <- Repo.get_by(Set, [organization_id: organization_id], log: false),
         {:ok, version, _} <- effective_version(set),
         {:ok, policy} <- snapshot(version),
         true <- selected?(policy.settings["allowed_agents"], agent) do
      {:ok, policy, current}
    else
      false -> {:error, :agent_not_allowed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :policy_unavailable}
    end
  end

  def model_access(identity, policy, agent_id, model) do
    {organization_id, agent} = identity_resources(identity, agent_id)

    granted? =
      case identity do
        %Scope{} -> Grants.includes?(identity.grants.models, model)
        %Principal{} -> true
      end

    if granted? && is_binary(model) && ResourceResolver.owned?(organization_id, :model, model),
      do: restrictions(policy.settings, organization_id, agent, model),
      else: {:error, :model_not_allowed}
  end

  defp identity_resources(%Principal{} = principal, _),
    do: {principal.organization_id, principal.agent_id}

  defp identity_resources(%Scope{} = scope, agent), do: {scope.organization.id, agent}

  defp catalog_identity(%Principal{} = principal, agent) do
    if agent in [nil, principal.agent_id],
      do: {:ok, principal.organization_id, principal.agent_id},
      else: {:error, :forbidden}
  end

  defp catalog_identity(%Scope{} = scope, agent) do
    if is_binary(agent) && Grants.includes?(scope.grants.agents, agent) &&
         active_agent?(scope.organization.id, agent),
       do: {:ok, scope.organization.id, agent},
       else: {:error, :forbidden}
  end

  @doc "Effective snapshots for active organizations plus the platform default, for readiness."
  def readiness_snapshots do
    sets =
      Repo.all(
        from(s in Set,
          left_join: o in Organization,
          on: o.id == s.organization_id,
          where: is_nil(s.organization_id) or o.status == :active
        ),
        log: false
      )

    Enum.reduce_while(sets, {:ok, []}, fn set, {:ok, snapshots} ->
      with {:ok, version, _} <- effective_version(set), {:ok, policy} <- snapshot(version) do
        {:cont, {:ok, [policy | snapshots]}}
      else
        _ -> {:halt, {:error, :policy_unavailable}}
      end
    end)
  end

  defp principal_valid?(principal) do
    Repo.exists?(
      from(k in ApiKey,
        join: a in Agent,
        on: a.id == k.agent_id and a.organization_id == k.organization_id,
        join: o in Organization,
        on: o.id == k.organization_id,
        where:
          k.id == ^principal.api_key_id and k.agent_id == ^principal.agent_id and
            k.organization_id == ^principal.organization_id,
        where:
          is_nil(k.revoked_at) and (is_nil(k.expires_at) or k.expires_at > ^DateTime.utc_now()),
        where: a.status == :active and o.status == :active
      )
    )
  end

  defp active_agent?(organization_id, id),
    do:
      Repo.exists?(
        from(a in Agent,
          where: a.organization_id == ^organization_id and a.id == ^id and a.status == :active
        )
      )

  defp restrictions(settings, organization_id, agent, model) do
    cond do
      !selected?(settings["allowed_agents"], agent) ->
        {:error, :agent_not_allowed}

      !model_selected?(settings["allowed_models"], organization_id, model) ->
        {:error, :model_not_allowed}

      Map.has_key?(settings["agent_models"], agent) &&
          !model_selected?(settings["agent_models"][agent], organization_id, model) ->
        {:error, :model_not_allowed}

      true ->
        :ok
    end
  end

  defp selected?(values, id), do: "*" in values || id in values

  defp model_selected?(["*"], organization_id, model),
    do: ResourceResolver.owned?(organization_id, :model, model)

  defp model_selected?(values, organization_id, model),
    do: model in values && ResourceResolver.owned?(organization_id, :model, model)
end
