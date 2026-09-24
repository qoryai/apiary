defmodule Apiary.Organisations do
  @moduledoc """
  Organisations, their hives, memberships and invitations.

  Every function that acts on behalf of a caller takes an `Apiary.Accounts.Scope`
  loaded with `load_scope/2`. The scope says who is calling; authorization never
  trusts the membership it carries, which may be as old as the LiveView that
  holds it. Every mutation reads the caller's membership again and decides on
  that row.

  A level change or a removal is announced on the `Apiary.PubSub` topic
  `membership_topic(user_id)` so the user's open pages reload their scope.
  """

  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Query, warn: false

  alias Apiary.Repo
  alias Apiary.Accounts.{Scope, User, UserNotifier}
  alias Apiary.Organisations.{Hive, Invitation, Membership, Organisation}

  @default_hive_name "Main"
  @max_pending_invitations 50

  ## Scope

  @doc """
  Loads the organisation, hive and membership into the scope: the user's
  membership in `organisation_id` when given and held, otherwise the user's
  earliest membership. A user without a membership gets the scope unchanged.
  """
  def load_scope(scope, organisation_id \\ nil)

  def load_scope(%Scope{user: %User{} = user} = scope, organisation_id) do
    membership =
      (organisation_id &&
         membership_query(user) |> where(organisation_id: ^organisation_id) |> Repo.one()) ||
        membership_query(user) |> limit(1) |> Repo.one()

    case membership do
      %Membership{} = membership ->
        %{
          scope
          | organisation: membership.organisation,
            hive: membership.hive,
            membership: membership
        }

      nil ->
        scope
    end
  end

  def load_scope(scope, _organisation_id), do: scope

  @doc "The user's memberships, preloaded with organisation and hive, oldest first."
  def list_memberships(%User{} = user) do
    user |> membership_query() |> Repo.all()
  end

  defp membership_query(%User{id: user_id}) do
    from m in Membership,
      where: m.user_id == ^user_id,
      order_by: [asc: m.inserted_at, asc: m.id],
      preload: [:organisation, :hive]
  end

  ## Sign-up

  @doc """
  Registers a user and places them in an organisation, in one transaction.

  Without an invitation token the user gets a new organisation named from the
  email's local part, a hive named "#{@default_hive_name}" and an owner membership.
  With a valid pending token the invitation is accepted instead: no organisation
  is created and the membership is at the invitation's level. An invalid or
  expired token behaves as no token.

  The invitation may also be given as the struct `get_invitation_by_token/1`
  returned earlier. Either way it is claimed inside the transaction: when someone
  else accepted it in the meantime, nothing is created and the changeset carries
  an error on `:email`.
  """
  def sign_up_user(attrs, invitation_or_token \\ nil) do
    user_changeset = User.email_changeset(%User{}, attrs)

    multi =
      case pending_invitation(invitation_or_token) do
        %Invitation{} = invitation -> invited_sign_up_multi(user_changeset, invitation)
        _ -> fresh_sign_up_multi(user_changeset)
      end

    case Repo.transaction(multi) do
      {:ok, %{user: user, organisation: organisation, hive: hive, membership: membership}} ->
        {:ok, %{user: user, organisation: organisation, hive: hive, membership: membership}}

      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp fresh_sign_up_multi(user_changeset) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, user_changeset)
    |> Ecto.Multi.insert(:organisation, fn %{user: user} ->
      Organisation.changeset(%Organisation{}, %{name: organisation_name_from_email(user.email)})
    end)
    |> Ecto.Multi.insert(:hive, fn %{organisation: organisation} ->
      %Hive{organisation_id: organisation.id}
      |> Hive.changeset(%{name: @default_hive_name})
    end)
    |> Ecto.Multi.insert(:membership, fn %{user: user, organisation: organisation, hive: hive} ->
      membership_changeset(organisation, hive, user, :owner)
    end)
  end

  defp invited_sign_up_multi(user_changeset, %Invitation{} = invitation) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, user_changeset)
    |> Ecto.Multi.put(:organisation, invitation.organisation)
    |> Ecto.Multi.put(:hive, invitation.hive)
    |> Ecto.Multi.run(:invitation, fn _repo, _changes ->
      # Lost to a concurrent accept: an error on the form rather than a second
      # membership from one invitation.
      with {:error, :invalid} <- claim_invitation(invitation) do
        {:error,
         user_changeset
         |> Ecto.Changeset.add_error(
           :email,
           dgettext_noop("errors", "was invited, but the invitation is no longer valid")
         )
         |> Map.put(:action, :insert)}
      end
    end)
    |> Ecto.Multi.insert(:membership, fn %{user: user} ->
      membership_changeset(invitation.organisation, invitation.hive, user, invitation.level)
    end)
  end

  defp membership_changeset(%Organisation{} = organisation, %Hive{} = hive, %User{} = user, level) do
    %Membership{organisation_id: organisation.id, hive_id: hive.id, user_id: user.id}
    |> Membership.changeset(%{level: level})
  end

  defp organisation_name_from_email(email) do
    case String.split(email, "@", parts: 2) do
      [local, _] when local != "" -> local
      _ -> email
    end
  end

  ## Settings

  def change_organisation(%Organisation{} = organisation, attrs \\ %{}) do
    Organisation.changeset(organisation, attrs)
  end

  @doc "Renames the scope's organisation. Owners only."
  def update_organisation(%Scope{organisation: %Organisation{} = organisation} = scope, attrs) do
    with :ok <- authorize_owner(scope) do
      organisation |> Organisation.changeset(attrs) |> Repo.update()
    end
  end

  def change_hive(%Hive{} = hive, attrs \\ %{}) do
    Hive.changeset(hive, attrs)
  end

  @doc "Renames the scope's hive. Owners only."
  def update_hive(%Scope{hive: %Hive{} = hive} = scope, attrs) do
    with :ok <- authorize_owner(scope) do
      hive |> Hive.changeset(attrs) |> Repo.update()
    end
  end

  ## Members

  @doc "The memberships of the scope's hive, preloaded with user: owners first, then by insertion."
  def list_members(%Scope{
        organisation: %Organisation{id: organisation_id},
        hive: %Hive{id: hive_id}
      }) do
    Repo.all(
      from m in Membership,
        where: m.organisation_id == ^organisation_id and m.hive_id == ^hive_id,
        order_by: [
          asc: fragment("CASE WHEN ? = 'owner' THEN 0 ELSE 1 END", m.level),
          asc: m.inserted_at,
          asc: m.id
        ],
        preload: [:user]
    )
  end

  @doc """
  Changes a member's level. Owners only; demoting the last owner is refused.
  """
  def set_member_level(%Scope{} = scope, membership_id, level) do
    level = normalise_level(level)

    with true <- level in Membership.levels() || {:error, :not_found} do
      fn ->
        with :ok <- lock_owners(scope),
             :ok <- authorize_owner(scope),
             {:ok, membership} <- get_member(scope, membership_id),
             :ok <- ensure_not_last_owner(membership, level) do
          membership |> Membership.changeset(%{level: level}) |> Repo.update()
        end
      end
      |> Repo.transact()
      |> broadcast_membership_change()
    end
  end

  @doc """
  Removes a member. Owners only; the last owner cannot be removed. An owner may
  remove themselves when another owner remains.
  """
  def remove_member(%Scope{} = scope, membership_id) do
    fn ->
      with :ok <- lock_owners(scope),
           :ok <- authorize_owner(scope),
           {:ok, membership} <- get_member(scope, membership_id),
           :ok <- ensure_not_last_owner(membership, :removed) do
        Repo.delete(membership)
      end
    end
    |> Repo.transact()
    |> broadcast_membership_change()
  end

  # Owners of the organisation are locked so two concurrent changes cannot both
  # see a second owner and remove them. The caller is authorized after the lock,
  # so a concurrent demotion of the caller is seen too.
  defp lock_owners(%Scope{organisation: %Organisation{id: organisation_id}}) do
    Repo.all(
      from m in Membership,
        where: m.organisation_id == ^organisation_id and m.level == :owner,
        select: m.id,
        lock: "FOR UPDATE"
    )

    :ok
  end

  defp lock_owners(_scope), do: :ok

  defp get_member(
         %Scope{organisation: %Organisation{id: organisation_id}, hive: %Hive{id: hive_id}},
         membership_id
       ) do
    with {:ok, membership_id} <- Ecto.UUID.cast(membership_id),
         %Membership{} = membership <-
           Repo.get_by(Membership,
             id: membership_id,
             organisation_id: organisation_id,
             hive_id: hive_id
           ) do
      {:ok, membership}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "The PubSub topic that announces changes to a user's memberships."
  def membership_topic(user_id), do: "membership:#{user_id}"

  defp broadcast_membership_change({:ok, %Membership{} = membership} = result) do
    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      membership_topic(membership.user_id),
      {:membership_changed, %{organisation_id: membership.organisation_id}}
    )

    result
  end

  defp broadcast_membership_change(result), do: result

  defp ensure_not_last_owner(%Membership{level: :owner} = membership, new_level)
       when new_level != :owner do
    other_owners =
      Repo.aggregate(
        from(m in Membership,
          where:
            m.organisation_id == ^membership.organisation_id and m.level == :owner and
              m.id != ^membership.id
        ),
        :count
      )

    if other_owners > 0, do: :ok, else: {:error, :last_owner}
  end

  defp ensure_not_last_owner(%Membership{}, _new_level), do: :ok

  defp normalise_level(level) when is_atom(level), do: level

  defp normalise_level(level) when is_binary(level) do
    Enum.find(Membership.levels(), level, &(Atom.to_string(&1) == level))
  end

  ## Invitations

  @doc "The organisation's pending invitations (not accepted, not expired), newest first."
  def list_invitations(%Scope{organisation: %Organisation{id: organisation_id}}) do
    now = DateTime.utc_now()

    Repo.all(
      from i in Invitation,
        where:
          i.organisation_id == ^organisation_id and is_nil(i.accepted_at) and i.expires_at > ^now,
        order_by: [desc: i.inserted_at, desc: i.id]
    )
  end

  def change_invitation(invitation \\ %Invitation{}, attrs \\ %{}) do
    Invitation.changeset(invitation, attrs)
  end

  @doc """
  Invites an email address to the scope's hive and emails the link built by
  `url_fun.(token)`. Owners only. An address that already belongs to a member of
  the organisation is refused with an error on `:email`.
  """
  def invite_member(%Scope{} = scope, attrs, url_fun) when is_function(url_fun, 1) do
    with :ok <- authorize_owner(scope) do
      %Scope{user: inviter, organisation: organisation, hive: hive} = scope
      {token, token_hash} = Invitation.build_token()

      changeset =
        %Invitation{
          organisation_id: organisation.id,
          hive_id: hive.id,
          invited_by_id: inviter.id,
          token_hash: token_hash,
          expires_at: DateTime.add(DateTime.utc_now(), Invitation.validity_days(), :day)
        }
        |> Invitation.changeset(attrs)
        |> refuse_existing_member(organisation)
        |> refuse_over_pending_cap(organisation)

      result =
        Repo.transact(fn ->
          with %Ecto.Changeset{valid?: true} = changeset <- changeset,
               :ok <-
                 delete_expired_invitations(
                   organisation,
                   Ecto.Changeset.get_field(changeset, :email)
                 ) do
            Repo.insert(changeset)
          else
            %Ecto.Changeset{} = changeset -> {:error, changeset}
          end
        end)

      with {:ok, invitation} <- result do
        case deliver_invitation(invitation, inviter, organisation, url_fun.(token)) do
          :ok ->
            {:ok, invitation}

          :error ->
            # An invitation nobody received must not occupy the pending slot.
            Repo.delete(invitation, allow_stale: true)
            {:error, :delivery_failed}
        end
      end
    end
  end

  defp deliver_invitation(%Invitation{email: email}, inviter, organisation, url) do
    case UserNotifier.deliver_invitation(email, inviter, organisation, url) do
      {:ok, _email} -> :ok
      _error -> :error
    end
  rescue
    # The reason may quote the message, which carries the link: not logged.
    _exception -> :error
  end

  defp refuse_over_pending_cap(%Ecto.Changeset{valid?: false} = changeset, _organisation),
    do: changeset

  defp refuse_over_pending_cap(changeset, %Organisation{id: organisation_id}) do
    now = DateTime.utc_now()

    pending =
      Repo.aggregate(
        from(i in Invitation,
          where:
            i.organisation_id == ^organisation_id and is_nil(i.accepted_at) and
              i.expires_at > ^now
        ),
        :count
      )

    if pending >= @max_pending_invitations,
      do:
        Ecto.Changeset.add_error(
          changeset,
          :email,
          dgettext_noop("errors", "too many pending invitations")
        ),
      else: changeset
  end

  defp refuse_existing_member(changeset, %Organisation{id: organisation_id}) do
    case Ecto.Changeset.get_field(changeset, :email) do
      nil ->
        changeset

      email ->
        member? =
          Repo.exists?(
            from m in Membership,
              join: u in assoc(m, :user),
              where: m.organisation_id == ^organisation_id and u.email == ^email
          )

        if member?,
          do:
            Ecto.Changeset.add_error(
              changeset,
              :email,
              dgettext_noop("errors", "is already a member of this organisation")
            ),
          else: changeset
    end
  end

  # An expired invitation still occupies the pending slot for its email; a new
  # invitation replaces it.
  defp delete_expired_invitations(%Organisation{id: organisation_id}, email) do
    now = DateTime.utc_now()

    Repo.delete_all(
      from i in Invitation,
        where:
          i.organisation_id == ^organisation_id and i.email == ^email and is_nil(i.accepted_at) and
            i.expires_at <= ^now
    )

    :ok
  end

  @doc "Deletes a pending invitation. Owners only."
  def revoke_invitation(
        %Scope{organisation: %Organisation{id: organisation_id}} = scope,
        invitation_id
      ) do
    with :ok <- authorize_owner(scope) do
      pending =
        from i in Invitation,
          where:
            i.id == ^invitation_id and i.organisation_id == ^organisation_id and
              is_nil(i.accepted_at)

      case Repo.one(pending) do
        %Invitation{} = invitation -> Repo.delete(invitation)
        nil -> {:error, :not_found}
      end
    end
  end

  @doc "The pending invitation behind a URL token, preloaded with organisation and hive, or nil."
  def get_invitation_by_token(token) when is_binary(token) do
    token_hash = Invitation.hash_token(token)
    now = DateTime.utc_now()

    Repo.one(
      from i in Invitation,
        where: i.token_hash == ^token_hash and is_nil(i.accepted_at) and i.expires_at > ^now,
        preload: [:organisation, :hive]
    )
  end

  def get_invitation_by_token(_token), do: nil

  defp pending_invitation(%Invitation{} = invitation),
    do: Repo.preload(invitation, [:organisation, :hive])

  defp pending_invitation(token), do: get_invitation_by_token(token)

  @doc """
  Accepts an invitation on behalf of a signed-in user: a membership at the
  invitation's level, and the invitation marked accepted. Takes the URL token or
  the invitation `get_invitation_by_token/1` returned earlier; the invitation is
  claimed inside the transaction, so it makes one membership however many
  callers hold it: the others get `{:error, :invalid}`.
  """
  def accept_invitation(%User{} = user, invitation_or_token) do
    case pending_invitation(invitation_or_token) do
      nil ->
        {:error, :invalid}

      %Invitation{} = invitation ->
        Repo.transact(fn ->
          if Repo.exists?(
               from m in Membership,
                 where: m.organisation_id == ^invitation.organisation_id and m.user_id == ^user.id
             ) do
            {:error, :already_member}
          else
            with {:ok, _invitation} <- claim_invitation(invitation) do
              Repo.insert(
                membership_changeset(
                  invitation.organisation,
                  invitation.hive,
                  user,
                  invitation.level
                )
              )
            end
          end
        end)
    end
  end

  # One invitation makes one membership: the row is claimed with a conditional
  # update, so of two concurrent accepts exactly one sees a count of 1. The
  # other waits on the row lock and then matches nothing.
  defp claim_invitation(%Invitation{id: id} = invitation) do
    now = DateTime.utc_now()

    claim =
      from i in Invitation,
        where: i.id == ^id and is_nil(i.accepted_at) and i.expires_at > ^now

    case Repo.update_all(claim, set: [accepted_at: now, updated_at: now]) do
      {1, _} -> {:ok, %{invitation | accepted_at: now}}
      {0, _} -> {:error, :invalid}
    end
  end

  ## Authorization

  @doc """
  Whether the scope's membership is an owner membership, as loaded. For what a
  page shows; a mutation authorizes on `fetch_membership/1`.
  """
  def owner?(%Scope{membership: %Membership{level: :owner}}), do: true
  def owner?(_scope), do: false

  @doc """
  The caller's membership as it is in the database now, or
  `{:error, :unauthorized}` when it is gone or the scope carries none.
  """
  def fetch_membership(%Scope{
        user: %User{id: user_id},
        organisation: %Organisation{id: organisation_id},
        hive: %Hive{id: hive_id},
        membership: %Membership{id: membership_id}
      }) do
    case Repo.get_by(Membership,
           id: membership_id,
           user_id: user_id,
           organisation_id: organisation_id,
           hive_id: hive_id
         ) do
      %Membership{} = membership -> {:ok, membership}
      nil -> {:error, :unauthorized}
    end
  end

  def fetch_membership(_scope), do: {:error, :unauthorized}

  defp authorize_owner(scope) do
    case fetch_membership(scope) do
      {:ok, %Membership{level: :owner}} -> :ok
      _ -> {:error, :unauthorized}
    end
  end
end
