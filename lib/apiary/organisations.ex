defmodule Apiary.Organisations do
  @moduledoc """
  Organisations, their workspaces, memberships and invitations.

  An organisation and a workspace each get a slug from their name when they are created
  (`Apiary.Organisations.Slug`); a page's path names them by it, and `resolve_scope/3`
  loads them for a member only.

  Every function that acts on behalf of a caller takes an `Apiary.Accounts.Scope`
  loaded with `load_scope/2`. The scope says who is calling; every mutation asks
  `Apiary.Access.authorize/3` first, which reads the caller's membership again rather
  than trust the one the scope carries, which may be as old as the LiveView that holds
  it.

  A level change or a removal is announced on the `Apiary.PubSub` topic
  `membership_topic(user_id)` so the user's open pages reload their scope.
  """

  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, Audit, Repo}
  alias Apiary.Accounts.{Scope, User, UserNotifier}
  alias Apiary.Organisations.{Workspace, Invitation, Membership, Organisation, Slug}

  @default_workspace_name "Main"
  @max_pending_invitations 50

  ## Scope

  @doc """
  Loads the organisation, workspace and membership into the scope: the user's
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
            workspace: membership.workspace,
            membership: membership
        }

      nil ->
        scope
    end
  end

  def load_scope(scope, _organisation_id), do: scope

  @doc """
  resolve_scope/3 loads the organisation whose slug is `organisation_slug`, and the
  workspace whose slug is `workspace_slug` in it, into the scope: `{:ok, scope}` when the
  user holds a membership there. Without a workspace slug, the workspace is the one of
  the user's membership in the organisation.

  `:error` when a slug names nothing and when it names an organisation or a workspace
  the user is not a member of: one answer for both, so a slug does not tell whether it
  exists.
  """
  @spec resolve_scope(Scope.t(), String.t(), String.t() | nil) :: {:ok, Scope.t()} | :error
  def resolve_scope(scope, organisation_slug, workspace_slug \\ nil)

  def resolve_scope(%Scope{user: %User{} = user} = scope, organisation_slug, workspace_slug)
      when is_binary(organisation_slug) do
    query =
      from m in Membership,
        join: o in assoc(m, :organisation),
        join: w in assoc(m, :workspace),
        where: m.user_id == ^user.id and o.slug == ^organisation_slug,
        preload: [organisation: o, workspace: w]

    query =
      if is_binary(workspace_slug),
        do: where(query, [_m, _o, w], w.slug == ^workspace_slug),
        else: query

    case Repo.one(query) do
      %Membership{} = membership -> {:ok, put_membership(scope, membership)}
      nil -> :error
    end
  end

  def resolve_scope(_scope, _organisation_slug, _workspace_slug), do: :error

  @doc """
  home_membership/2 is the membership whose workspace a signed-in user is sent to: the
  one of `workspace_id`, the workspace the session remembers as last opened, while the
  user still holds it; otherwise the user's earliest. Nil without a membership.
  """
  @spec home_membership(%User{}, String.t() | nil) :: %Membership{} | nil
  def home_membership(%User{} = user, workspace_id \\ nil) do
    memberships = list_memberships(user)
    Enum.find(memberships, &(&1.workspace_id == workspace_id)) || List.first(memberships)
  end

  @doc """
  load_home_scope/2 loads the organisation, workspace and membership of
  `home_membership/2` into the scope, for a page of the user's own that shows the
  workspace beside it. A user without a membership gets the scope unchanged.
  """
  @spec load_home_scope(Scope.t() | nil, String.t() | nil) :: Scope.t() | nil
  def load_home_scope(%Scope{user: %User{} = user} = scope, workspace_id) do
    case home_membership(user, workspace_id) do
      %Membership{} = membership -> put_membership(scope, membership)
      nil -> scope
    end
  end

  def load_home_scope(scope, _workspace_id), do: scope

  @doc """
  job_scope/3 is the scope a job acts under (`Apiary.Job`), built from the
  ids its arguments carry: the organisation, the workspace in it when `workspace_id` is not
  nil, and the person whose action enqueued the job when `user_id` is not nil, with their
  membership there when they still hold one. Without a person the scope is the
  instance's (`Apiary.Accounts.Scope.for_instance/2`): the instance acts, as its role in
  `Apiary.Access` allows. Without an organisation the scope is the instance's alone.

  `:error` when the organisation, the workspace in it or the person no longer exists.
  """
  @spec job_scope(Ecto.UUID.t() | nil, Ecto.UUID.t() | nil, Ecto.UUID.t() | nil) ::
          {:ok, Scope.t()} | :error
  def job_scope(organisation_id, workspace_id, user_id) do
    with {:ok, user} <- fetch_job_user(user_id),
         {:ok, organisation} <- fetch_job_organisation(organisation_id),
         {:ok, workspace} <- fetch_job_workspace(organisation, workspace_id) do
      case user do
        nil ->
          {:ok, Scope.for_instance(organisation, workspace)}

        %User{} ->
          {:ok,
           %Scope{
             user: user,
             organisation: organisation,
             workspace: workspace,
             membership: job_membership(user, organisation, workspace)
           }}
      end
    end
  end

  defp fetch_job_user(nil), do: {:ok, nil}

  defp fetch_job_user(user_id) do
    case Repo.get(User, user_id) do
      %User{} = user -> {:ok, user}
      nil -> :error
    end
  end

  defp fetch_job_organisation(nil), do: {:ok, nil}

  defp fetch_job_organisation(organisation_id) do
    case Repo.get(Organisation, organisation_id) do
      %Organisation{} = organisation -> {:ok, organisation}
      nil -> :error
    end
  end

  defp fetch_job_workspace(_organisation, nil), do: {:ok, nil}
  defp fetch_job_workspace(nil, _workspace_id), do: :error

  defp fetch_job_workspace(%Organisation{id: organisation_id}, workspace_id) do
    case Repo.get_by(Workspace, id: workspace_id, organisation_id: organisation_id) do
      %Workspace{} = workspace -> {:ok, workspace}
      nil -> :error
    end
  end

  defp job_membership(_user, nil, _workspace), do: nil

  defp job_membership(%User{} = user, %Organisation{id: organisation_id}, workspace) do
    query = user |> membership_query() |> where(organisation_id: ^organisation_id)

    query =
      case workspace do
        %Workspace{id: workspace_id} -> where(query, workspace_id: ^workspace_id)
        nil -> query
      end

    query |> limit(1) |> Repo.one()
  end

  @typedoc "Where a page of ids ends: the id of its last row; nil before the first page."
  @type page_cursor :: Ecto.UUID.t() | nil

  @doc """
  One page of the ids of every organisation on the instance, in the order of their ids: at
  most `limit` after `cursor`, and the cursor the next page starts after. For work done
  once per organisation (`Apiary.Job.insert_per_organisation/3`); each page is one short
  query on the primary key's index, so nothing is held open between pages.
  """
  @spec page_organisation_ids(page_cursor(), pos_integer()) ::
          {[Ecto.UUID.t()], page_cursor()}
  def page_organisation_ids(cursor, limit) do
    from(o in Organisation, select: {o.id, o.id}) |> page_ids(cursor, limit)
  end

  @doc """
  One page of the organisation and workspace ids of every workspace on the instance, in the
  order of the workspaces' ids, as `page_organisation_ids/2` pages organisations. For work
  done once per workspace (`Apiary.Job.insert_per_workspace/3`).
  """
  @spec page_workspace_ids(page_cursor(), pos_integer()) ::
          {[{Ecto.UUID.t(), Ecto.UUID.t()}], page_cursor()}
  def page_workspace_ids(cursor, limit) do
    from(w in Workspace, select: {w.id, {w.organisation_id, w.id}}) |> page_ids(cursor, limit)
  end

  # Keyset pages on the primary key: a sweep needs every row once, in no particular order.
  defp page_ids(query, cursor, limit) do
    query = if cursor, do: where(query, [r], r.id > ^cursor), else: query
    rows = query |> order_by([r], asc: r.id) |> limit(^limit) |> Repo.all()

    case List.last(rows) do
      nil -> {[], cursor}
      {id, _ids} -> {Enum.map(rows, &elem(&1, 1)), id}
    end
  end

  defp put_membership(scope, %Membership{} = membership) do
    %{
      scope
      | organisation: membership.organisation,
        workspace: membership.workspace,
        membership: membership
    }
  end

  @doc "The user's memberships, preloaded with organisation and workspace, oldest first."
  def list_memberships(%User{} = user) do
    user |> membership_query() |> Repo.all()
  end

  defp membership_query(%User{id: user_id}) do
    from m in Membership,
      where: m.user_id == ^user_id,
      order_by: [asc: m.inserted_at, asc: m.id],
      preload: [:organisation, :workspace]
  end

  ## Sign-up

  @sign_up_types %{email: :string, organisation_name: :string}

  @doc """
  change_sign_up/2 is the changeset of the sign-up form: `email`, checked as an account's
  address is, and, for a sign-up without an invitation, `organisation_name`, the name of
  the organisation it creates, checked as an organisation's name is. `invited: true` for
  a sign-up with an invitation, which creates no organisation and asks for no name;
  `validate_unique: false` leaves out the read of whether the address is taken, as the
  form does while it is typed in.
  """
  @spec change_sign_up(map, keyword) :: Ecto.Changeset.t()
  def change_sign_up(attrs \\ %{}, opts \\ []) do
    unique? = Keyword.get(opts, :validate_unique, true)
    user = User.email_changeset(%User{}, attrs, validate_unique: unique?)

    form =
      {%{}, @sign_up_types}
      |> Ecto.Changeset.cast(attrs, Map.keys(@sign_up_types))
      |> Ecto.Changeset.update_change(:organisation_name, &String.trim/1)
      |> copy_errors(user)

    if Keyword.get(opts, :invited, false) do
      form
    else
      name = Ecto.Changeset.get_field(form, :organisation_name)
      copy_errors(form, Organisation.changeset(%Organisation{}, %{name: name}))
    end
  end

  # The errors of the account's or the organisation's changeset, on the form's fields: the
  # address on `email`, the organisation's name and slug on `organisation_name`, and
  # anything else on `email`, which is where the form says it could not sign up.
  defp copy_errors(form, %Ecto.Changeset{errors: errors}) do
    Enum.reduce(errors, form, fn {field, {message, keys}}, form ->
      field = if field in [:name, :slug], do: :organisation_name, else: :email
      Ecto.Changeset.add_error(form, field, message, keys)
    end)
  end

  @doc """
  Registers a user and places them in an organisation, in one transaction.

  Without an invitation token the user gets a new organisation named `organisation_name`,
  with a slug made from that name, a workspace named "#{@default_workspace_name}" and an
  owner membership: nothing is made from the address. With a valid pending token the
  invitation is accepted instead: no organisation is created, no name is asked for, and
  the membership is at the invitation's level. An invalid or expired token behaves as no
  token.

  A refusal is `{:error, changeset}`, the changeset of the sign-up form
  (`change_sign_up/2`), with its errors on `email` and `organisation_name`.

  The invitation may also be given as the struct `get_invitation_by_token/1`
  returned earlier. Either way it is claimed inside the transaction: when someone
  else accepted it in the meantime, nothing is created and the changeset carries
  an error on `:email`. So it does when every slug picked for the new organisation was
  taken by a concurrent sign-up before the insert, a few times over.

  The audit trail has the sign-up, by the new user: `organisation.create` for a new
  organisation, `invitation.accept` for an invitation, from `origin:` (see
  `Apiary.Accounts.Scope.put_origin/2`), the request's address and client.

  `opts` is also for tests: `pick_slug: fun`, given the organisation's name, stands in for
  the pick of a free slug.
  """
  def sign_up_user(attrs, invitation_or_token \\ nil, opts \\ []) do
    pick = Keyword.get(opts, :pick_slug, &organisation_slug/1)
    origin = Keyword.get(opts, :origin)
    invitation = pending_invitation(invitation_or_token)
    invited? = match?(%Invitation{}, invitation)
    form = change_sign_up(attrs, invited: invited?, validate_unique: false)

    if form.valid? do
      email = Ecto.Changeset.get_field(form, :email)
      user_changeset = User.email_changeset(%User{}, %{email: email})

      multi =
        if invited?,
          do: invited_sign_up_multi(user_changeset, invitation, origin),
          else:
            fresh_sign_up_multi(
              user_changeset,
              Ecto.Changeset.get_field(form, :organisation_name),
              pick,
              origin
            )

      case Repo.transaction(multi) do
        {:ok,
         %{user: user, organisation: organisation, workspace: workspace, membership: membership}} ->
          {:ok,
           %{user: user, organisation: organisation, workspace: workspace, membership: membership}}

        {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, form |> copy_errors(changeset) |> Map.put(:action, :insert)}
      end
    else
      {:error, Map.put(form, :action, :insert)}
    end
  end

  defp fresh_sign_up_multi(user_changeset, name, pick, origin) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, user_changeset)
    |> Ecto.Multi.run(:organisation, fn _repo, _changes ->
      case insert_organisation(name, pick) do
        {:ok, organisation} ->
          {:ok, organisation}

        {:error, :slug_taken} ->
          {:error,
           user_changeset
           |> Ecto.Changeset.add_error(
             :email,
             dgettext_noop("errors", "could not be signed up just now; please try again")
           )
           |> Map.put(:action, :insert)}

        {:error, changeset} ->
          {:error, changeset}
      end
    end)
    |> Ecto.Multi.insert(:workspace, fn %{organisation: organisation} ->
      %Workspace{organisation_id: organisation.id}
      |> Workspace.create_changeset(%{
        name: @default_workspace_name,
        domain: Apiary.Lingo.Domain.default().name()
      })
      |> Workspace.put_slug(workspace_slug(organisation, @default_workspace_name))
    end)
    |> Ecto.Multi.insert(:membership, fn %{
                                           user: user,
                                           organisation: organisation,
                                           workspace: workspace
                                         } ->
      membership_changeset(organisation, workspace, user, :owner)
    end)
    |> Audit.record(
      &sign_up_scope(&1, origin),
      :"organisation.create",
      & &1.organisation,
      &%{details: %{workspace_id: &1.workspace.id, membership_id: &1.membership.id}}
    )
  end

  # The new user, acting in the organisation they signed up into.
  defp sign_up_scope(%{user: user, organisation: organisation, workspace: workspace}, origin) do
    %Scope{user: user, organisation: organisation, workspace: workspace, origin: origin}
  end

  defp invited_sign_up_multi(user_changeset, %Invitation{} = invitation, origin) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, user_changeset)
    |> Ecto.Multi.put(:organisation, invitation.organisation)
    |> Ecto.Multi.put(:workspace, invitation.workspace)
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
      membership_changeset(invitation.organisation, invitation.workspace, user, invitation.level)
    end)
    |> Audit.record(
      &sign_up_scope(&1, origin),
      :"invitation.accept",
      invitation,
      &accepted(invitation, &1.membership)
    )
  end

  # An accepted invitation: the level it gave and the membership it became; never the
  # address it was sent to.
  defp accepted(%Invitation{level: level}, %Membership{id: id}),
    do: %{after: %{level: level}, details: %{membership_id: id}}

  defp membership_changeset(
         %Organisation{} = organisation,
         %Workspace{} = workspace,
         %User{} = user,
         level
       ) do
    %Membership{organisation_id: organisation.id, workspace_id: workspace.id, user_id: user.id}
    |> Membership.changeset(%{level: level})
  end

  @slug_attempts 5

  # Inserts a new organisation with a slug `pick` makes from its name. The slug is picked
  # by asking which are taken, so two sign-ups may pick the same one at once. The insert
  # does nothing on the unique index instead of failing, which would abort the
  # transaction; the organisation is then not there, and a new slug is picked, as often
  # as `@slug_attempts`. `{:error, :slug_taken}` when every attempt lost.
  defp insert_organisation(name, pick, attempts \\ @slug_attempts)

  defp insert_organisation(_name, _pick, 0), do: {:error, :slug_taken}

  defp insert_organisation(name, pick, attempts) do
    changeset =
      %Organisation{}
      |> Organisation.changeset(%{name: name})
      |> Organisation.put_slug(pick.(name))

    with {:ok, %Organisation{id: id} = organisation} <-
           Repo.insert(changeset, on_conflict: :nothing, conflict_target: :slug) do
      if Repo.exists?(from o in Organisation, where: o.id == ^id),
        do: {:ok, organisation},
        else: insert_organisation(name, pick, attempts - 1)
    end
  end

  defp organisation_slug(name) do
    name
    |> Slug.from_name("organisation")
    |> Slug.pick(ApiaryWeb.ReservedSlugs.organisation(), fn slug ->
      Repo.exists?(from o in Organisation, where: o.slug == ^slug)
    end)
  end

  defp workspace_slug(%Organisation{id: organisation_id}, name) do
    name
    |> Slug.from_name("workspace")
    |> Slug.pick(ApiaryWeb.ReservedSlugs.workspace(), fn slug ->
      Repo.exists?(
        from w in Workspace, where: w.organisation_id == ^organisation_id and w.slug == ^slug
      )
    end)
  end

  ## Settings

  def change_organisation(%Organisation{} = organisation, attrs \\ %{}) do
    Organisation.changeset(organisation, attrs)
  end

  @doc "Renames the scope's organisation (`organisation.rename`), with its audit entry."
  def update_organisation(%Scope{organisation: %Organisation{} = organisation} = scope, attrs) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"organisation.rename", organisation),
           {:ok, renamed} <- organisation |> Organisation.changeset(attrs) |> Repo.update(),
           :ok <- record_edit(scope, :"organisation.rename", organisation, renamed, [:name]) do
        {:ok, renamed}
      end
    end)
  end

  def change_workspace(%Workspace{} = workspace, attrs \\ %{}) do
    Workspace.changeset(workspace, attrs)
  end

  @doc "Renames the scope's workspace (`workspace.rename`), with its audit entry."
  def update_workspace(%Scope{workspace: %Workspace{} = workspace} = scope, attrs) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"workspace.rename", workspace),
           {:ok, renamed} <- workspace |> Workspace.changeset(attrs) |> Repo.update(),
           :ok <- record_edit(scope, :"workspace.rename", workspace, renamed, [:name]) do
        {:ok, renamed}
      end
    end)
  end

  # The entry of an edit, when it changed one of `fields`; an edit that changed nothing
  # has nothing to record.
  defp record_edit(scope, action, old, new, fields) do
    case Audit.changed(old, new, fields) do
      nil ->
        :ok

      changes ->
        with {:ok, _entry} <- Audit.record(Repo, scope, action, new, changes), do: :ok
    end
  end

  @doc "list_workspaces/1 is the workspaces of the scope's organisation, by name."
  @spec list_workspaces(Scope.t()) :: [%Workspace{}]
  def list_workspaces(%Scope{organisation: %Organisation{id: organisation_id}}) do
    Repo.all(
      from w in Workspace,
        where: w.organisation_id == ^organisation_id,
        order_by: [asc: w.name, asc: w.id]
    )
  end

  ## Members

  @doc "The memberships of the scope's workspace, preloaded with user: owners first, then by insertion."
  def list_members(%Scope{
        organisation: %Organisation{id: organisation_id},
        workspace: %Workspace{id: workspace_id}
      }) do
    Repo.all(
      from m in Membership,
        where: m.organisation_id == ^organisation_id and m.workspace_id == ^workspace_id,
        order_by: [
          asc: fragment("CASE WHEN ? = 'owner' THEN 0 ELSE 1 END", m.level),
          asc: m.inserted_at,
          asc: m.id
        ],
        preload: [:user]
    )
  end

  @doc """
  Changes a member's level (`member.change_level`); demoting the last owner is refused.
  """
  def set_member_level(%Scope{} = scope, membership_id, level) do
    level = normalise_level(level)

    with true <- level in Membership.levels() || {:error, :not_found} do
      fn ->
        with :ok <- lock_owners(scope),
             :ok <- Access.authorize(scope, :"member.change_level", scope.workspace),
             {:ok, membership} <- get_member(scope, membership_id),
             :ok <- ensure_not_last_owner(membership, level),
             {:ok, changed} <-
               membership |> Membership.changeset(%{level: level}) |> Repo.update(),
             :ok <- record_member(scope, :"member.change_level", membership, changed) do
          {:ok, changed}
        end
      end
      |> Repo.transact()
      |> broadcast_membership_change()
    end
  end

  @doc """
  Removes a member (`member.remove`); the last owner cannot be removed. An owner may
  remove themselves when another owner remains.
  """
  def remove_member(%Scope{} = scope, membership_id) do
    fn ->
      with :ok <- lock_owners(scope),
           :ok <- Access.authorize(scope, :"member.remove", scope.workspace),
           {:ok, membership} <- get_member(scope, membership_id),
           :ok <- ensure_not_last_owner(membership, :removed),
           {:ok, removed} <- Repo.delete(membership),
           :ok <- record_member(scope, :"member.remove", membership, nil) do
        {:ok, removed}
      end
    end
    |> Repo.transact()
    |> broadcast_membership_change()
  end

  # A membership's entry names its person by their user id, in `details`, since the
  # membership of a removed member is gone.
  defp record_member(scope, :"member.remove" = action, %Membership{} = membership, nil) do
    data = %{before: %{level: membership.level}, details: %{user_id: membership.user_id}}
    with {:ok, _entry} <- Audit.record(Repo, scope, action, membership, data), do: :ok
  end

  defp record_member(scope, action, %Membership{} = old, %Membership{} = new) do
    case Audit.changed(old, new, [:level]) do
      nil ->
        :ok

      changes ->
        data = Map.put(changes, :details, %{user_id: new.user_id})
        with {:ok, _entry} <- Audit.record(Repo, scope, action, new, data), do: :ok
    end
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
         %Scope{
           organisation: %Organisation{id: organisation_id},
           workspace: %Workspace{id: workspace_id}
         },
         membership_id
       ) do
    with {:ok, membership_id} <- Ecto.UUID.cast(membership_id),
         %Membership{} = membership <-
           Repo.get_by(Membership,
             id: membership_id,
             organisation_id: organisation_id,
             workspace_id: workspace_id
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
  Invites an email address to the scope's workspace and emails the link built by
  `url_fun.(token)` (`member.invite`). An address that already belongs to a member of
  the organisation is refused with an error on `:email`.

  The invitation and its audit entry (`member.invite`) are committed first, and the email
  is sent after, so no transaction waits on the mail relay. An invitation that could not
  be delivered is then withdrawn, `{:error, :delivery_failed}`: deleted, in a second
  transaction, with an entry of `invitation.revoke` by the same person, its reason
  `undelivered`, when it is still pending then. One the invitee accepted meanwhile (the
  relay took the message and failed after) is kept and returned, `{:ok, invitation}`: it
  arrived. One an owner revoked meanwhile is gone already; neither writes an entry.
  Should the withdrawal itself fail, the invitation stays pending, undelivered:
  `{:error, :delivery_failed_pending}`, for an owner to revoke.

  An expired invitation to the same address, which would hold its pending place, is
  deleted with the new one's, an `invitation.revoke` entry each, their reason `expired`.
  The entries name an invitation and its level, never the address.
  """
  def invite_member(%Scope{} = scope, attrs, url_fun) when is_function(url_fun, 1) do
    with :ok <- Access.authorize(scope, :"member.invite", scope.workspace) do
      %Scope{user: inviter, organisation: organisation, workspace: workspace} = scope
      {token, token_hash} = Invitation.build_token()

      changeset =
        %Invitation{
          organisation_id: organisation.id,
          workspace_id: workspace.id,
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
                   scope,
                   Ecto.Changeset.get_field(changeset, :email)
                 ),
               {:ok, invitation} <- Repo.insert(changeset),
               {:ok, _entry} <-
                 Audit.record(Repo, scope, :"member.invite", invitation, %{
                   after: %{level: invitation.level}
                 }) do
            {:ok, invitation}
          else
            %Ecto.Changeset{} = changeset -> {:error, changeset}
            {:error, _reason} = error -> error
          end
        end)

      with {:ok, invitation} <- result do
        case deliver_invitation(invitation, inviter, organisation, url_fun.(token)) do
          :ok ->
            {:ok, invitation}

          :error ->
            # An invitation nobody received must not occupy the pending slot.
            case withdraw_undelivered(scope, invitation) do
              {:ok, {:accepted, accepted}} -> {:ok, accepted}
              {:ok, _withdrawn_or_gone} -> {:error, :delivery_failed}
              {:error, _reason} -> {:error, :delivery_failed_pending}
            end
        end
      end
    end
  end

  # The invitation, as it is now, locked: a revocation or an acceptance of it waits, and
  # one that came first is seen. Still pending, it is deleted, and the trail says why: its
  # inviter revoked nothing, the mail relay refused it. Accepted meanwhile, the email did
  # arrive, whatever the relay answered: it is kept, and the invitation stands. Revoked
  # meanwhile, it is gone, and its revocation is in the trail already. Not asked of
  # `Apiary.Access`: it undoes the caller's own invitation, which it was allowed a moment
  # ago. A withdrawal the database refuses leaves the invitation pending, and is logged;
  # `invite_member/3` says so, `{:error, :delivery_failed_pending}`.
  defp withdraw_undelivered(%Scope{} = scope, %Invitation{id: id}) do
    Repo.transact(fn ->
      case Repo.one(from i in Invitation, where: i.id == ^id, lock: "FOR UPDATE") do
        nil ->
          {:ok, :gone}

        %Invitation{accepted_at: %DateTime{}} = accepted ->
          {:ok, {:accepted, accepted}}

        %Invitation{} = pending ->
          with {:ok, _deleted} <- Repo.delete(pending),
               {:ok, _entry} <-
                 Audit.record(Repo, scope, :"invitation.revoke", pending, %{
                   before: %{level: pending.level},
                   details: %{reason: "undelivered"}
                 }) do
            {:ok, :withdrawn}
          end
      end
    end)
    |> case do
      {:ok, outcome} ->
        {:ok, outcome}

      {:error, _reason} = error ->
        Logger.error("invitation not withdrawn after a failed delivery invitation=#{id}")
        error
    end
  rescue
    # The database is away, or a statement failed: the kind of failure only.
    error ->
      Logger.error(
        "invitation not withdrawn after a failed delivery invitation=#{id} " <>
          "error=#{inspect(error.__struct__)}"
      )

      {:error, :not_withdrawn}
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
  # invitation replaces it. Each deleted is an entry of the trail, by the person whose
  # invitation replaced it, as they asked for the deletion.
  defp delete_expired_invitations(
         %Scope{organisation: %Organisation{id: organisation_id}} = scope,
         email
       ) do
    now = DateTime.utc_now()

    {_count, expired} =
      Repo.delete_all(
        from i in Invitation,
          where:
            i.organisation_id == ^organisation_id and i.email == ^email and
              is_nil(i.accepted_at) and i.expires_at <= ^now,
          select: i
      )

    Enum.reduce_while(expired, :ok, fn invitation, :ok ->
      case Audit.record(Repo, scope, :"invitation.revoke", invitation, %{
             before: %{level: invitation.level},
             details: %{reason: "expired"}
           }) do
        {:ok, _entry} -> {:cont, :ok}
        {:error, _changeset} = error -> {:halt, error}
      end
    end)
  end

  @doc "Deletes a pending invitation (`invitation.revoke`)."
  def revoke_invitation(
        %Scope{organisation: %Organisation{} = organisation} = scope,
        invitation_id
      ) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"invitation.revoke", organisation),
           %Invitation{} = invitation <- Repo.one(pending_invitation_query(scope, invitation_id)),
           {:ok, revoked} <- Repo.delete(invitation),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"invitation.revoke", invitation, %{
               before: %{level: invitation.level}
             }) do
        {:ok, revoked}
      else
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp pending_invitation_query(%Scope{organisation: %Organisation{id: organisation_id}}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        from i in Invitation,
          where: i.id == ^id and i.organisation_id == ^organisation_id and is_nil(i.accepted_at),
          lock: "FOR UPDATE"

      :error ->
        from i in Invitation, where: false
    end
  end

  @doc "The pending invitation behind a URL token, preloaded with organisation and workspace, or nil."
  def get_invitation_by_token(token) when is_binary(token) do
    token_hash = Invitation.hash_token(token)
    now = DateTime.utc_now()

    Repo.one(
      from i in Invitation,
        where: i.token_hash == ^token_hash and is_nil(i.accepted_at) and i.expires_at > ^now,
        preload: [:organisation, :workspace]
    )
  end

  def get_invitation_by_token(_token), do: nil

  defp pending_invitation(%Invitation{} = invitation),
    do: Repo.preload(invitation, [:organisation, :workspace])

  defp pending_invitation(token), do: get_invitation_by_token(token)

  @doc """
  Accepts an invitation on behalf of a signed-in user, the scope's: a membership at the
  invitation's level, the invitation marked accepted, and the audit entry of
  `invitation.accept`, by the user. Takes the URL token or the invitation
  `get_invitation_by_token/1` returned earlier; the invitation is claimed inside the
  transaction, so it makes one membership however many callers hold it: the others get
  `{:error, :invalid}`. The token is the check: nobody's role is asked. A user alone, not
  a scope, is accepted as a scope without an origin.
  """
  def accept_invitation(%User{} = user, invitation_or_token),
    do: accept_invitation(Scope.for_user(user), invitation_or_token)

  def accept_invitation(%Scope{user: %User{} = user} = scope, invitation_or_token) do
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
            with {:ok, _invitation} <- claim_invitation(invitation),
                 {:ok, membership} <-
                   Repo.insert(
                     membership_changeset(
                       invitation.organisation,
                       invitation.workspace,
                       user,
                       invitation.level
                     )
                   ),
                 {:ok, _entry} <-
                   Audit.record(
                     Repo,
                     %{
                       scope
                       | organisation: invitation.organisation,
                         workspace: invitation.workspace
                     },
                     :"invitation.accept",
                     invitation,
                     accepted(invitation, membership)
                   ) do
              {:ok, membership}
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
end
