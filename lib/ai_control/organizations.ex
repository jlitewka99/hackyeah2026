defmodule AiControl.Organizations do
  @moduledoc "Organization boundaries, administrative roles, and transactional member access."
  import Ecto.Query

  alias AiControl.Accounts.{Scope, User}
  alias AiControl.Organizations.{Grants, Invitation, Membership, Organization, ResourceResolver}
  alias AiControl.Repo

  def change_organization(attrs \\ %{}), do: Organization.changeset(%Organization{}, attrs)

  def create_organization(scope, attrs) do
    with {:ok, user} <- caller(scope), true <- user.organizer do
      result = Repo.insert(change_organization(attrs))

      if match?({:ok, _}, result),
        do:
          Phoenix.PubSub.broadcast(
            AiControl.PubSub,
            "platform:organizations",
            :organizations_changed
          )

      result
    else
      _ -> {:error, :forbidden}
    end
  end

  def list_organizations(scope) do
    case caller(scope) do
      {:ok, user} ->
        query = from(o in Organization, order_by: [asc: fragment("lower(?)", o.name), asc: o.id])

        query =
          if user.organizer,
            do: query,
            else:
              from(o in query,
                join: m in Membership,
                on: m.organization_id == o.id,
                where: m.user_id == ^user.id and o.status == :active
              )

        Repo.all(query)

      _ ->
        []
    end
  end

  def fetch_scope(scope, organization_id) do
    with {:ok, id} <- Ecto.UUID.cast(organization_id),
         {:ok, user} <- caller(scope),
         %Organization{} = organization <- Repo.get(Organization, id) do
      build_scope(user, organization)
    else
      _ -> {:error, :not_found}
    end
  end

  def refresh_scope(%Scope{organization: %Organization{id: id}} = scope),
    do: fetch_scope(scope, id)

  def refresh_scope(_), do: {:error, :not_found}

  defp build_scope(%User{organizer: true} = user, organization),
    do:
      {:ok,
       %Scope{
         user: user,
         organization: organization,
         grants: Grants.full(),
         access_mode: :organizer
       }}

  defp build_scope(user, %Organization{status: :active} = organization) do
    case Repo.get_by(Membership, organization_id: organization.id, user_id: user.id) do
      nil ->
        {:error, :not_found}

      membership ->
        {:ok,
         %Scope{
           user: user,
           organization: organization,
           membership: membership,
           grants: effective_grants(membership),
           access_mode: :member
         }}
    end
  end

  defp build_scope(_, _), do: {:error, :not_found}

  def effective_grants(%Membership{role: :superadmin}), do: Grants.full()
  def effective_grants(%Membership{grants: grants}), do: grants || %Grants{}
  def managers?(%Scope{access_mode: :organizer}), do: true
  def managers?(%Scope{membership: %Membership{role: role}}), do: role in [:superadmin, :admin]
  def managers?(_), do: false
  def privileged?(%Scope{access_mode: :organizer}), do: true
  def privileged?(%Scope{membership: %Membership{role: :superadmin}}), do: true
  def privileged?(_), do: false

  def list_members(scope) do
    with {:ok, current} <- refresh_scope(scope), :ok <- require_manager(current) do
      {:ok,
       Repo.all(
         from(m in Membership,
           where: m.organization_id == ^current.organization.id,
           order_by: [asc: m.inserted_at, asc: m.id],
           preload: [:user]
         )
       )}
    end
  end

  def list_invitations(scope) do
    with {:ok, current} <- refresh_scope(scope), :ok <- require_manager(current) do
      query =
        from(i in Invitation,
          where: i.organization_id == ^current.organization.id,
          order_by: [desc: i.inserted_at, desc: i.id]
        )

      query = if privileged?(current), do: query, else: from(i in query, where: i.role == :user)
      {:ok, Repo.all(query)}
    end
  end

  def get_member(scope, id) do
    with {:ok, current} <- refresh_scope(scope),
         :ok <- require_manager(current),
         {:ok, id} <- Ecto.UUID.cast(id),
         %Membership{} = member <-
           Repo.get_by(Membership, id: id, organization_id: current.organization.id),
         :ok <- editable_member(current, member) do
      {:ok, Repo.preload(member, :user)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  def update_member(scope, id, attrs) do
    locked(scope, fn current ->
      with {:ok, member} <- get_member(current, id),
           changeset = Membership.changeset(member, attrs),
           true <- changeset.valid?,
           proposed = Ecto.Changeset.apply_changes(changeset),
           :ok <- allowed_role(current, proposed.role),
           {:ok, grants} <- delegated_grants(current, member.grants, proposed.grants),
           :ok <- validate_resources(current.organization.id, grants) do
        changeset |> Ecto.Changeset.put_embed(:grants, Grants.attrs(grants)) |> Repo.update()
      else
        false -> {:error, Membership.changeset(%Membership{}, attrs)}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def remove_member(scope, id) do
    locked(scope, fn current ->
      with {:ok, member} <- get_member(current, id), do: Repo.delete(member)
    end)
  end

  def transfer_superadmin(scope, target_id) do
    locked(scope, fn current ->
      with true <- privileged?(current),
           {:ok, id} <- Ecto.UUID.cast(target_id),
           %Membership{role: :admin} = target <-
             Repo.get_by(Membership, id: id, organization_id: current.organization.id),
           %Membership{} = owner <-
             Repo.get_by(Membership, organization_id: current.organization.id, role: :superadmin),
           {:ok, _} <- Repo.update(Ecto.Changeset.change(owner, role: :admin)),
           {:ok, target} <- Repo.update(Membership.changeset(target, %{role: :superadmin})) do
        {:ok, target}
      else
        _ -> {:error, :forbidden}
      end
    end)
  end

  def set_status(scope, status) when status in [:active, :suspended] do
    locked(scope, fn current ->
      if current.access_mode == :organizer,
        do: Repo.update(Ecto.Changeset.change(current.organization, status: status)),
        else: {:error, :forbidden}
    end)
  end

  def set_status(_, _), do: {:error, :forbidden}

  def locked(%Scope{organization: %Organization{id: id}} = scope, fun) do
    result =
      Repo.transact(fn ->
        with %Organization{} <-
               Repo.one(from(o in Organization, where: o.id == ^id, lock: "FOR UPDATE")),
             {:ok, current} <- fetch_scope(scope, id) do
          fun.(current)
        else
          _ -> {:error, :not_found}
        end
      end)

    if match?({:ok, _}, result), do: notify(id)

    case result do
      {:ok, %Membership{user_id: user_id}} -> notify_user(user_id)
      _ -> :ok
    end

    result
  end

  def locked(_, _), do: {:error, :not_found}

  def notify(id) do
    Phoenix.PubSub.broadcast(
      AiControl.PubSub,
      "organizations:#{id}:access",
      {:organization_access_changed, id}
    )

    Phoenix.PubSub.broadcast(AiControl.PubSub, "platform:organizations", :organizations_changed)

    Repo.all(from(m in Membership, where: m.organization_id == ^id, select: m.user_id))
    |> Enum.each(&notify_user/1)
  end

  defp notify_user(id),
    do:
      Phoenix.PubSub.broadcast(
        AiControl.PubSub,
        "users:#{id}:organizations",
        :organizations_changed
      )

  def caller(%Scope{user: %User{id: id}}) do
    case Repo.get(User, id, log: false) do
      %User{} = user -> {:ok, user}
      _ -> {:error, :forbidden}
    end
  end

  def caller(_), do: {:error, :forbidden}
  def require_manager(scope), do: if(managers?(scope), do: :ok, else: {:error, :forbidden})

  def allowed_role(scope, role) do
    cond do
      role == :superadmin -> {:error, :forbidden}
      privileged?(scope) && role in [:admin, :user] -> :ok
      managers?(scope) && role == :user -> :ok
      true -> {:error, :forbidden}
    end
  end

  def editable_member(scope, member) do
    cond do
      member.role == :superadmin -> {:error, :forbidden}
      privileged?(scope) -> :ok
      managers?(scope) && member.role == :user -> :ok
      true -> {:error, :forbidden}
    end
  end

  def validate_resources(organization_id, grants) do
    valid? =
      Enum.all?(
        grants.agents,
        &(&1 == "*" || ResourceResolver.owned?(organization_id, :agent, &1))
      ) &&
        Enum.all?(
          grants.models,
          &(&1 == "*" || ResourceResolver.owned?(organization_id, :model, &1))
        )

    if valid?, do: :ok, else: {:error, :unknown_resource}
  end

  def delegated_grants(scope, old, proposed) do
    old = old || %Grants{}

    if privileged?(scope) do
      {:ok, proposed}
    else
      own = scope.grants

      preserved = %Grants{
        permissions: old.permissions -- own.permissions,
        agents: outside(old.agents, own.agents),
        models: outside(old.models, own.models)
      }

      ceiling = %Grants{
        permissions: Enum.uniq(own.permissions ++ preserved.permissions),
        agents: Enum.uniq(own.agents ++ preserved.agents),
        models: Enum.uniq(own.models ++ preserved.models)
      }

      if Grants.subset?(proposed, ceiling) do
        {:ok,
         %Grants{
           permissions: Enum.uniq(proposed.permissions ++ preserved.permissions),
           agents: merge_selectors(proposed.agents, preserved.agents),
           models: merge_selectors(proposed.models, preserved.models)
         }}
      else
        {:error, :forbidden}
      end
    end
  end

  defp outside(_, ["*"]), do: []
  defp outside(old, own), do: old -- own

  defp merge_selectors(requested, preserved),
    do: if("*" in preserved, do: ["*"], else: Enum.uniq(requested ++ preserved))
end
