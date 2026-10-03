defmodule AiControl.Organizations.Invitations do
  @moduledoc "Single-use invitations; account activation and membership creation share one transaction."
  import Ecto.Query
  import Swoosh.Email, except: [from: 2]

  alias AiControl.Accounts.{Scope, User}
  alias AiControl.{Mailer, Repo}
  alias AiControl.Organizations
  alias AiControl.Organizations.{Grants, Invitation, Membership, Organization}

  def change_invitation(attrs \\ %{}), do: Invitation.changeset(%Invitation{}, attrs)

  def issue(scope, attrs, url_fun) when is_function(url_fun, 1) do
    result = Organizations.locked(scope, fn current -> create_invitation(current, attrs) end)

    with {:ok, {invitation, token, name}} <- result do
      deliver(invitation, name, url_fun.(token))
    end
  end

  defp create_invitation(scope, attrs) do
    token = :crypto.strong_rand_bytes(32)

    invitation = %Invitation{
      organization_id: scope.organization.id,
      invited_by_id: scope.user.id,
      token_hash: :crypto.hash(:sha256, token),
      expires_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
    }

    changeset = Invitation.changeset(invitation, attrs)
    proposed = Ecto.Changeset.apply_changes(changeset)

    with true <- scope.organization.status == :active,
         true <- changeset.valid?,
         :ok <- allowed_invitation(scope, proposed),
         true <- Grants.subset?(proposed.grants, scope.grants),
         :ok <- Organizations.validate_resources(scope.organization.id, proposed.grants),
         false <- member_email?(scope.organization.id, proposed.email),
         :ok <- no_pending_owner(scope, proposed.role),
         {:ok, inserted} <- Repo.insert(changeset, log: false) do
      {:ok, {inserted, Base.url_encode64(token, padding: false), scope.organization.name}}
    else
      false ->
        if(changeset.valid?,
          do: {:error, :forbidden},
          else: {:error, %{changeset | action: :insert}}
        )

      true ->
        {:error, :already_member}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp allowed_invitation(%Scope{access_mode: :organizer} = scope, %{role: :superadmin}) do
    if Repo.exists?(
         from(m in Membership,
           where: m.organization_id == ^scope.organization.id and m.role == :superadmin
         )
       ), do: {:error, :forbidden}, else: :ok
  end

  defp allowed_invitation(scope, invitation),
    do: Organizations.allowed_role(scope, invitation.role)

  defp no_pending_owner(scope, :superadmin) do
    pending? =
      Repo.exists?(
        from(i in Invitation,
          where:
            i.organization_id == ^scope.organization.id and i.role == :superadmin and
              is_nil(i.revoked_at) and is_nil(i.accepted_at) and
              i.expires_at > ^DateTime.utc_now(:second)
        )
      )

    if pending?, do: {:error, :pending_superadmin}, else: :ok
  end

  defp no_pending_owner(_, _), do: :ok

  defp member_email?(organization_id, email),
    do:
      Repo.exists?(
        from(m in Membership,
          join: u in assoc(m, :user),
          where: m.organization_id == ^organization_id and u.email == ^email
        )
      )

  def revoke(scope, id) do
    Organizations.locked(scope, fn current ->
      with {:ok, invitation} <- manageable_invitation(current, id),
           true <- is_nil(invitation.accepted_at) do
        Repo.update(Ecto.Changeset.change(invitation, revoked_at: DateTime.utc_now(:second)),
          log: false
        )
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_invitation}
      end
    end)
  end

  def resend(scope, id, url_fun) do
    with {:ok, invitation} <- revoke(scope, id) do
      attrs = %{
        email: invitation.email,
        role: invitation.role,
        grants: Grants.attrs(invitation.grants)
      }

      issue(scope, attrs, url_fun)
    end
  end

  defp manageable_invitation(scope, id) do
    with :ok <- Organizations.require_manager(scope),
         {:ok, id} <- Ecto.UUID.cast(id),
         %Invitation{} = invitation <-
           Repo.get_by(Invitation, [id: id, organization_id: scope.organization.id], log: false),
         true <- Organizations.privileged?(scope) || invitation.role == :user do
      {:ok, invitation}
    else
      _ -> {:error, :not_found}
    end
  end

  def preview(token) do
    with {:ok, hash} <- hash_token(token),
         %Invitation{} = invitation <- Repo.get_by(Invitation, [token_hash: hash], log: false),
         true <- Invitation.pending?(invitation),
         %Organization{status: :active} = organization <-
           Repo.get(Organization, invitation.organization_id) do
      {:ok,
       %{
         invitation: invitation,
         organization: organization,
         existing_account?:
           Repo.exists?(from(u in User, where: u.email == ^invitation.email), log: false)
       }}
    else
      _ -> {:error, :invalid_invitation}
    end
  end

  def accept(token, scope, attrs) do
    with {:ok, preview} <- preview(token) do
      id = preview.organization.id
      result = Repo.transact(fn -> accept_locked(id, token, scope, attrs) end)
      if match?({:ok, _}, result), do: Organizations.notify(id)
      result
    end
  end

  defp accept_locked(organization_id, token, scope, attrs) do
    with %Organization{status: :active} <-
           Repo.one(from(o in Organization, where: o.id == ^organization_id, lock: "FOR UPDATE")),
         {:ok, hash} <- hash_token(token),
         %Invitation{} = invitation <-
           Repo.one(
             from(i in Invitation,
               where: i.organization_id == ^organization_id and i.token_hash == ^hash,
               lock: "FOR UPDATE"
             ),
             log: false
           ),
         true <- Invitation.pending?(invitation),
         {:ok, issuer} <-
           Organizations.fetch_scope(
             %Scope{user: %User{id: invitation.invited_by_id}},
             organization_id
           ),
         :ok <- allowed_invitation(issuer, invitation),
         true <- Grants.subset?(invitation.grants, issuer.grants),
         :ok <- Organizations.validate_resources(organization_id, invitation.grants),
         {:ok, user} <- invited_user(invitation, scope, attrs),
         {:ok, membership} <-
           Repo.insert(
             Membership.changeset(
               %Membership{organization_id: organization_id, user_id: user.id},
               %{role: invitation.role, grants: Grants.attrs(invitation.grants)}
             )
           ),
         {:ok, _} <-
           Repo.update(Ecto.Changeset.change(invitation, accepted_at: DateTime.utc_now(:second)),
             log: false
           ) do
      {:ok, %{user: user, membership: membership, organization_id: organization_id}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_invitation}
    end
  end

  defp invited_user(invitation, scope, attrs) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtext($1))",
      ["invitation-email:#{invitation.email}"],
      log: false
    )

    user =
      Repo.one(from(u in User, where: u.email == ^invitation.email, lock: "FOR UPDATE"),
        log: false
      )

    resolve_user(user, scope, invitation.email, attrs)
  end

  defp resolve_user(nil, nil, email, attrs) do
    %User{confirmed_at: DateTime.utc_now(:second)}
    |> User.email_changeset(%{email: email})
    |> User.password_changeset(attrs, require_confirmation: true)
    |> Repo.insert(log: false)
  end

  defp resolve_user(%User{} = user, %Scope{user: %User{id: id}}, _, _) when id == user.id,
    do: {:ok, user}

  defp resolve_user(%User{}, nil, _, _), do: {:error, :authentication_required}
  defp resolve_user(_, _, _, _), do: {:error, :wrong_account}

  defp hash_token(token) when is_binary(token) do
    with {:ok, decoded} <- Base.url_decode64(token, padding: false),
         true <- byte_size(decoded) == 32 do
      {:ok, :crypto.hash(:sha256, decoded)}
    else
      _ -> {:error, :invalid_invitation}
    end
  end

  defp hash_token(_), do: {:error, :invalid_invitation}

  defp deliver(invitation, name, url) do
    email =
      new()
      |> to(invitation.email)
      |> Swoosh.Email.from({"AiControl", "contact@example.com"})
      |> subject("Join #{name} on AiControl")
      |> text_body(
        "You have been invited to #{name} as #{invitation.role}.\n\nAccept this one-time invitation within 24 hours:\n#{url}\n\nIf you did not expect this invitation, ignore this email."
      )

    case Mailer.deliver(email) do
      {:ok, _} ->
        {:ok, invitation}

      {:error, _} ->
        Repo.update!(Ecto.Changeset.change(invitation, revoked_at: DateTime.utc_now(:second)),
          log: false
        )

        Organizations.notify(invitation.organization_id)
        {:error, :delivery_failed}
    end
  end
end
