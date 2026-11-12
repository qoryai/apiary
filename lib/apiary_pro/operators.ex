defmodule ApiaryPro.Operators do
  @moduledoc """
  Operators and their clients, and the instance actions of the instance organisation's
  owners.

  ## Clients

  An operator provides a harness, its agents, skills, workflows and integrations, that
  its clients run on Qory Apiary, and keeps it working. Each client is an organisation of
  the kind `organisation` whose tenant's `operator_id` is the operator
  (`ApiaryPro.Tenants.Tenant`), and owns its people as any organisation does: its
  owners, admins and members, its invitations, its settings and its policy. The operator's
  people read everything in each client, at any level they hold in the operator, and
  change nothing there (`Apiary.Access`, Reach).

  An owner or an admin of the operator creates a client (`create_client/3`,
  `client.create`): named, with a slug and no workspace, and invites its first owner by
  email (`client.invite_owner`), who becomes its owner on accepting and creates its first
  workspace from the kind cards on its overview (`/:org`); while the operator runs its
  clients, the first person is its admin, who creates it as an owner does, and an owner of
  the operator may too. The
  invitation counts against the operator's allowance of invitations. While a client has no
  owner, the operator invites one again (`invite_owner/4`), makes a new link for a
  pending invitation of one (`renew_owner_invitation/4`), revokes an invitation of one
  (`revoke_owner_invitation/3`), and deletes it (`ApiaryPro.Deletion.delete_client/3`),
  since nobody else is in it; it drops a client that has an owner. `list_clients/1` is the
  operator's Clients page. An operator drops a client at once, the client's name typed to
  confirm (`ApiaryPro.Transfers`).

  ## The instance

  The instance organisation's owners, the instance admins, take the instance actions on
  Instance settings' pages, each asked of `Apiary.Access` in the instance organisation:

  - `list_organisations/1` (`instance.read`): every organisation on the instance, with its
    kind, its operator and whether it is marked for deletion;
  - `create_organisation/2` (`instance.create_organisation`, `instance.create_operator`):
    an organisation or an operator, with no workspace, whose first owner is the
    instance admin who created it, who makes its first workspace from the kind cards on
    its overview (`/:org`), invites its people and may leave once another owner is
    there;
  - `change_kind/3` (`instance.change_kind`): an organisation that is no client made an
    operator, or an operator without clients made an organisation, the instance
    organisation as any other;
  - purging an organisation at once, on an erasure request, is `Apiary.Deletion`'s
    (`ApiaryPro.Deletion.purge_on_request/3`).

  Every change is an audit entry, written in its transaction (`Apiary.Audit`): a client's
  creation (`client.create`), an organisation's creation by the instance and a change of
  kind (`instance.create_organisation`, `instance.create_operator`,
  `instance.change_kind`) are entries of the organisation created or changed, whose trail
  they begin or continue, by the person who acted.
  """

  use Gettext, backend: ApiaryProWeb.Gettext
  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Invitation, Membership, Organisation, Workspace}
  alias ApiaryPro.{Grants, Reach, Tenants, Transfers}
  alias ApiaryPro.Operators.OperatorInvitation
  alias ApiaryPro.Tenants.Tenant

  @typedoc """
  A client on its operator's Clients page: its owners' accounts, none deleted, by when
  they joined; the operator's pending invitations of its first owner, oldest first; how
  many people it has; and whether it has a workspace in use.
  """
  @type client_row :: %{
          organisation: %Organisation{},
          owners: [%Apiary.Accounts.User{}],
          owner_invitations: [%Invitation{}],
          people: non_neg_integer,
          workspace?: boolean
        }

  @typedoc "An organisation on Instance settings › Organisations."
  @type instance_row :: %{
          organisation: %Organisation{},
          operator: %Organisation{} | nil,
          clients: non_neg_integer,
          only_owner?: boolean
        }

  ## Clients

  @doc """
  change_client/1 is the changeset of the form that names a new client, or a new
  organisation on Instance settings › Organisations: its name, checked as an organisation's name
  is.
  """
  @spec change_client(map) :: Ecto.Changeset.t()
  def change_client(attrs \\ %{}), do: Organisation.changeset(%Organisation{}, attrs)

  @doc """
  change_new_client/1 is the changeset of the form that creates a client: its name, as
  `change_client/1` checks it, and `email`, the address of its first owner, checked as an
  invitation's is.
  """
  @spec change_new_client(map) :: Ecto.Changeset.t()
  def change_new_client(attrs \\ %{}) do
    email = attrs["email"] || attrs[:email]
    invitation = Invitation.changeset(%Invitation{}, %{"email" => email})

    Enum.reduce(invitation.errors, change_client(attrs), fn {:email, {message, opts}}, form ->
      Ecto.Changeset.add_error(form, :email, message, opts)
    end)
  end

  @doc """
  list_clients/1 is the clients of the scope's organisation, an operator, by name, each
  carrying its tenant, which says since when it is the operator's client
  (`ApiaryPro.Tenants.operator_since/1`), with its owners' accounts, the operator's
  pending invitations of its first owner, how many people it has, and whether it has a
  workspace in use (`workspace?`) (`client.read`): those marked for deletion among them,
  which the page says. `{:ok, rows}`; `{:error, :not_found}` in an organisation that is no operator, or where
  `managed_organisations` is off, and `Apiary.Access`'s answer otherwise.
  """
  @spec list_clients(Scope.t()) :: {:ok, [client_row]} | {:error, Access.reason()}
  def list_clients(%Scope{organisation: %Organisation{id: operator_id} = operator} = scope) do
    with :ok <- Access.authorize(scope, :"client.read", operator) do
      rows =
        Repo.all(
          from o in Organisation,
            join: t in Tenant,
            on: t.organisation_id == o.id,
            left_join: m in Membership,
            on: m.organisation_id == o.id,
            where: t.operator_id == ^operator_id,
            group_by: [o.id, t.organisation_id],
            order_by: [asc: o.name, asc: o.id],
            select: %{organisation: o, tenant: t, people: count(m.id)}
        )
        |> Enum.map(fn %{organisation: organisation, tenant: tenant} = row ->
          row
          |> Map.delete(:tenant)
          |> Map.put(:organisation, Tenants.put_tenant(organisation, tenant))
        end)

      ids = Enum.map(rows, & &1.organisation.id)
      owners = people_of(ids, :owner)
      invitations = owner_invitations(operator_id, ids)
      with_workspace = with_workspace(ids)

      # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, each client's admins too,
      # whom the operator's invitation makes its first.
      admins = if ApiaryPro.Flags.operator_infrastructure?(), do: people_of(ids, :admin)

      {:ok,
       Enum.map(rows, fn %{organisation: %{id: id}} = row ->
         row
         |> Map.merge(%{
           owners: Map.get(owners, id, []),
           owner_invitations: Map.get(invitations, id, []),
           workspace?: MapSet.member?(with_workspace, id)
         })
         |> then(&if(admins, do: Map.put(&1, :admins, Map.get(admins, id, [])), else: &1))
       end)}
    end
  end

  def list_clients(_scope), do: {:error, :not_found}

  # The clients among `client_ids` with a workspace in use, none marked for deletion: one
  # read.
  defp with_workspace(client_ids) do
    Repo.all(
      from w in Workspace,
        where: w.organisation_id in ^client_ids and is_nil(w.deletion_marked_at),
        distinct: true,
        select: w.organisation_id
    )
    |> MapSet.new()
  end

  # The operator's pending invitations of the first owner of each client, oldest first:
  # one read.
  defp owner_invitations(operator_id, client_ids) do
    now = DateTime.utc_now()

    Repo.all(
      from i in Invitation,
        join: o in OperatorInvitation,
        on: o.invitation_id == i.id,
        where: i.organisation_id in ^client_ids and o.operator_id == ^operator_id,
        where: is_nil(i.accepted_at) and i.expires_at > ^now,
        order_by: [asc: i.inserted_at, asc: i.id]
    )
    |> Enum.group_by(& &1.organisation_id)
  end

  # The accounts of each organisation's people at `level`, none deleted, by when they
  # joined: one read.
  defp people_of(organisation_ids, level) do
    Repo.all(
      from m in Membership,
        join: u in assoc(m, :user),
        where: m.organisation_id in ^organisation_ids and m.level == ^level,
        where: is_nil(u.deleted_at),
        order_by: [asc: m.inserted_at, asc: m.id],
        select: {m.organisation_id, u}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  count_clients/1 is how many clients the scope's organisation manages in use, none marked
  for deletion: 0 for an organisation that is no operator. For the sidebar, which shows
  it beside Clients once `Apiary.Access.can?/3` allows `client.read`.
  """
  @spec count_clients(Scope.t()) :: non_neg_integer
  def count_clients(%Scope{organisation: %Organisation{id: id} = organisation}) do
    if Tenants.operator?(organisation) do
      Repo.aggregate(
        from(o in Organisation,
          join: t in Tenant,
          on: t.organisation_id == o.id,
          where: t.operator_id == ^id and is_nil(o.deletion_marked_at)
        ),
        :count
      )
    else
      0
    end
  end

  def count_clients(_scope), do: 0

  @doc """
  operator_of/1 is the operator of the scope's organisation, when it is a client: the
  organisation whose harness it runs, which its settings page names, and which its owners
  may leave. Nil for an organisation that is no client.
  """
  @spec operator_of(Scope.t()) :: %Organisation{} | nil
  def operator_of(%Scope{organisation: %Organisation{} = organisation}) do
    case Tenants.operator_id(organisation) do
      nil -> nil
      operator_id -> Organisation |> Repo.get(operator_id) |> then(&(&1 && Tenants.put(&1)))
    end
  end

  def operator_of(_scope), do: nil

  @doc """
  create_client/3 creates a client of the scope's organisation, an operator
  (`client.create`, an owner's or an admin's of the operator): an organisation of the kind
  `organisation` named `attrs["name"]`, with a slug made from its name, no workspace, and
  the operator as its operator (`Apiary.Organisations.build_organisation/2`), and invites
  its first owner, `attrs["email"]` (`client.invite_owner`), to the organisation alone,
  against the operator's allowance of invitations
  (`Apiary.Organisations.insert_invitation/3`, with a scope that has no workspace). The
  client has no people until they accept: then they are its owner, and they create its
  first workspace from the kind cards on its overview (`/:org`,
  `Apiary.Organisations.create_workspace_of_kind/3`). While the operator runs its clients,
  they are its admin instead, who creates it as an owner does; an owner of the operator
  may too. Its trail begins with the entry of `client.create`, by the person who created
  it, which names the operator, and the entry of the invitation follows. The operator's
  people are told
  (`Apiary.Organisations.membership_topic/1`), so their switchers show it. The invitation
  is handed over, the link built by `url_fun.(token)`, once the client is committed: with
  mail (`Apiary.Mail.configured?/0`) it is emailed; without, it is kept, and its link is
  handed back for the operator's person to copy, once.

  `{:ok, %{organisation: client, sent: sent}}`, `sent` what
  `Apiary.Organisations.send_invitation/4` answered: `{:ok, invitation}` when it was
  emailed, `{:ok, invitation, {:link, url}}` without mail, or an error for one that could
  not be delivered, which the operator sends again with `invite_owner/4`, and
  `{:error, :unconfirmed}` for one withdrawn unsent, mail set since it was written for a
  person whose address is not confirmed;
  `{:error, changeset}`, the changeset of `change_new_client/1`, for a name or an address
  it refuses, the day's invitations spent included, and for a name whose address another
  organisation or a page of Qory Apiary has (`taken: :refuse`: nothing is numbered), and
  nothing is created; `{:error, :unconfirmed}` with mail, for a person whose
  address is not confirmed, and nothing is created; `{:error, :not_found}` in an
  organisation that is no operator, and `Apiary.Access`'s answer otherwise.
  """
  @spec create_client(Scope.t(), map, (String.t() -> String.t())) ::
          {:ok,
           %{
             organisation: %Organisation{},
             sent:
               {:ok, %Invitation{}}
               | {:ok, %Invitation{}, {:link, String.t()}}
               | {:error, term}
           }}
          | {:error, Ecto.Changeset.t() | :unconfirmed | Access.reason()}
  def create_client(%Scope{organisation: %Organisation{} = operator} = scope, attrs, url_fun)
      when is_function(url_fun, 1) do
    form = change_new_client(attrs)

    # The operator's row `FOR NO KEY UPDATE` first, which the count of its invitations
    # needs: its deletion, its purge and a change of its kind lock it for update, so they
    # wait for the client, whose foreign key they then see, or come first, and the
    # creation's question to `Apiary.Access` reads them. It asks before the name is
    # checked, so a refusal is said before the form's.
    Ecto.Multi.new()
    |> Ecto.Multi.run(:asked, fn _repo, _changes ->
      with :ok <- lock_operator(operator),
           :ok <- Access.authorize(scope, :"client.create", operator),
           do: {:ok, nil}
    end)
    |> Organisations.build_organisation(
      name: Ecto.Changeset.get_field(form, :name),
      owner: nil,
      workspace: false,
      action: :"client.create",
      taken: :refuse,
      how: {:client, operator},
      scope: &Reach.in_client(scope, &1.organisation)
    )
    |> Ecto.Multi.run(:invited, fn _repo, %{created: created} ->
      # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, the first person is
      # invited as the client's admin.
      first = if ApiaryPro.Flags.operator_infrastructure?(), do: :admin, else: :owner

      case invite(scope, operator, created.organisation, nil, attrs, first) do
        {:ok, invitation, token} -> {:ok, {invitation, token}}
        {:error, _reason} = error -> error
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{created: %{organisation: client}, invited: invited}} ->
        {invitation, token} = invited
        tell_the_people_of(operator)

        sent =
          Organisations.send_invitation(
            owner_scope(scope, client, nil),
            invitation,
            token,
            url_fun
          )

        {:ok, %{organisation: client, sent: sent}}

      {:error, :invited, reason, _changes} ->
        on_form({:error, reason}, form)

      refused ->
        refusal(refused, form)
    end
  end

  def create_client(_scope, _attrs, _url_fun), do: {:error, :not_found}

  @doc """
  invite_owner/4 invites the first owner of the client `client_id` of the scope's
  organisation, an operator, while the client has no owner (`client.invite_owner`, an
  owner's or an admin's of the operator): an invitation to `attrs["email"]` to its first
  workspace in use, or to the organisation alone while it has none, against the operator's
  allowance of invitations, as `create_client/3` sends one, handed over once it is
  committed: emailed with mail (`Apiary.Mail.configured?/0`), its link handed back
  without. Its person becomes the client's owner on accepting. An entry of `client.invite_owner` in the client's trail, by
  the person who invited.

  `{:ok, invitation}` when it was emailed; `{:ok, invitation, {:link, url}}` without
  mail, the link to show once; `{:error, changeset}` for an address the invitation refuses, the
  day's invitations spent included; `{:error, :has_owner}` for a client that has an owner,
  who invites its people; `{:error, :suspended}` for a suspended client;
  `{:error, :delivery_failed}` or `{:error, :delivery_failed_pending}` for one that could
  not be delivered; `{:error, :unconfirmed}` with mail, for an inviter whose address is
  not confirmed, the invitation withdrawn unsent should mail be set since it was written;
  `{:error, :not_found}` for an organisation that is no client of the
  operator, or one marked for deletion, and `Apiary.Access`'s answer otherwise.
  """
  @spec invite_owner(Scope.t(), Ecto.UUID.t(), map, (String.t() -> String.t())) ::
          {:ok, %Invitation{}}
          | {:ok, %Invitation{}, {:link, String.t()}}
          | {:error,
             Ecto.Changeset.t()
             | :has_owner
             | :suspended
             | :delivery_failed
             | :delivery_failed_pending
             | Access.reason()
             | term}
  def invite_owner(scope, client_id, attrs, url_fun),
    do: invite_first(scope, client_id, attrs, url_fun, :owner)

  # Hidden while `ApiaryPro.Flags.operator_infrastructure?/0` is off, so not in the
  # published documentation.
  #
  # invite_admin/4 invites the first admin of the client `client_id` of the scope's
  # organisation, an operator, while the client has no owner and no admin
  # (`client.invite_admin`, an owner's or an admin's of the operator), as `invite_owner/4`
  # invites its first owner: its person becomes the client's admin on accepting. An entry
  # of `client.invite_admin` in the client's trail. `{:error, :has_admin}` for a client
  # that has an owner or an admin, who invites its people; the rest as `invite_owner/4`.
  @doc false
  @spec invite_admin(Scope.t(), Ecto.UUID.t(), map, (String.t() -> String.t())) ::
          {:ok, %Invitation{}}
          | {:ok, %Invitation{}, {:link, String.t()}}
          | {:error, Ecto.Changeset.t() | :has_admin | :suspended | Access.reason() | term}
  def invite_admin(scope, client_id, attrs, url_fun),
    do: invite_first(scope, client_id, attrs, url_fun, :admin)

  defp invite_first(
         %Scope{organisation: %Organisation{id: operator_id} = operator} = scope,
         client_id,
         attrs,
         url_fun,
         first
       )
       when is_function(url_fun, 1) do
    with {:ok, id} <- cast(client_id) do
      Repo.transact(fn ->
        # The lock order (docs/access.md): the client's row `FOR SHARE`, which its
        # leaving and its drop wait for, and the operator's `FOR NO KEY UPDATE`, which the
        # count of its invitations needs, at one point, in the lock order; the core's
        # invitation takes the operator's again, in the same mode.
        held = lock_client_and_allowance(id, operator_id)

        with %Organisation{deletion_marked_at: nil} = client <- held[id] || {:error, :not_found},
             true <- Tenants.operator_id(client) == operator_id || {:error, :not_found},
             :ok <- Access.authorize(scope, invite_action(first), operator),
             false <- Tenants.suspended?(client) && {:error, :suspended},
             :ok <- nobody_first(client, first),
             # None while the client has no workspace: the invitation is to the organisation
             # alone, and the core refuses it once a workspace is in use.
             workspace = first_workspace(client),
             {:ok, invitation, token} <- invite(scope, operator, client, workspace, attrs, first) do
          {:ok, {client, workspace, invitation, token}}
        else
          %Organisation{} -> {:error, :not_found}
          {:error, _reason} = error -> error
        end
      end)
      |> case do
        {:ok, {client, workspace, invitation, token}} ->
          Organisations.send_invitation(
            owner_scope(scope, client, workspace),
            invitation,
            token,
            url_fun
          )

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp invite_first(_scope, _client_id, _attrs, _url_fun, _first), do: {:error, :not_found}

  @doc """
  revoke_owner_invitation/3 deletes the pending invitation `invitation_id` of the first
  owner of the client `client_id` of the scope's organisation, an operator
  (`client.revoke_owner_invitation`, an owner's or an admin's of the operator), while the
  client has no owner: an address mistyped, or sent to someone who should not own it,
  never joins. An entry of `client.revoke_owner_invitation` in the client's trail, by the
  person who revoked it.

  `{:ok, invitation}`, as it was; `{:error, :has_owner}` for a client that has an owner,
  whose owners revoke its invitations; `{:error, :not_found}` for an invitation that is
  no pending invitation of the client's first owner by this operator, one accepted or
  revoked meanwhile included, for an organisation that is no client of the operator, and
  `Apiary.Access`'s answer otherwise.
  """
  @spec revoke_owner_invitation(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, %Invitation{}} | {:error, :has_owner | Access.reason() | term}
  def revoke_owner_invitation(scope, client_id, invitation_id),
    do: revoke_first_invitation(scope, client_id, invitation_id, :owner)

  # Hidden while `ApiaryPro.Flags.operator_infrastructure?/0` is off, so not in the
  # published documentation.
  #
  # revoke_admin_invitation/3 deletes the pending invitation `invitation_id` of the first
  # admin of the client `client_id` (`client.revoke_admin_invitation`), while the client
  # has no owner and no admin, as `revoke_owner_invitation/3` deletes one of
  # its first owner. `{:error, :has_admin}` for a client that has one.
  @doc false
  @spec revoke_admin_invitation(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, %Invitation{}} | {:error, :has_admin | Access.reason() | term}
  def revoke_admin_invitation(scope, client_id, invitation_id),
    do: revoke_first_invitation(scope, client_id, invitation_id, :admin)

  defp revoke_first_invitation(
         %Scope{organisation: %Organisation{id: operator_id} = operator} = scope,
         client_id,
         invitation_id,
         first
       ) do
    with {:ok, id} <- cast(client_id),
         {:ok, invitation_id} <- cast(invitation_id) do
      Repo.transact(fn ->
        # The lock order (docs/access.md): the client's row `FOR SHARE`, which the
        # acceptance of its first owner's invitation locks for update, so it came first
        # and is seen, or waits; then the invitation.
        with %Organisation{deletion_marked_at: nil} = client <-
               Tenants.lock_organisation(id, "FOR SHARE") || {:error, :not_found},
             true <- Tenants.operator_id(client) == operator_id || {:error, :not_found},
             :ok <- Access.authorize(scope, revoke_action(first), operator),
             :ok <- nobody_first(client, first),
             %Invitation{} = invitation <-
               Repo.one(
                 from i in Invitation,
                   join: o in OperatorInvitation,
                   on: o.invitation_id == i.id,
                   where: i.id == ^invitation_id and i.organisation_id == ^id,
                   where: o.operator_id == ^operator_id and is_nil(i.accepted_at),
                   lock: fragment("FOR UPDATE OF ?", i)
               ) || {:error, :not_found},
             {:ok, revoked} <- Repo.delete(invitation),
             {:ok, _entry} <-
               Audit.record(
                 Repo,
                 Reach.in_client(scope, client),
                 revoke_action(first),
                 invitation,
                 %{}
               ) do
          {:ok, revoked}
        else
          %Organisation{} -> {:error, :not_found}
          {:error, _reason} = error -> error
        end
      end)
    end
  end

  defp revoke_first_invitation(_scope, _client_id, _invitation_id, _first),
    do: {:error, :not_found}

  @doc """
  renew_owner_invitation/4 makes a new link for the pending invitation `invitation_id` of
  the first owner of the client `client_id` of the scope's organisation, an operator
  (`client.renew_owner_invitation`, an owner's or an admin's of the operator), while the
  client has no owner and is not suspended, for one whose link was lost: the same
  invitation, so its row of `operator_invitations` stands, with a new token and its days
  again from now; only the new token's hash is kept, so the old link stops working at
  once (`Apiary.Organisations.renew_invitation/4`, with `action:`). It counts against the
  operator's allowance of invitations, as the invitation did. An entry of
  `client.renew_owner_invitation` in the client's trail, by the person who made it,
  naming the operator's allowance (`details.allowance_id`). The new link is handed over
  once it is committed, as `invite_owner/4` hands over a new invitation: emailed with
  mail (`Apiary.Mail.configured?/0`), handed back without.

  `{:ok, invitation}` when it was emailed; `{:ok, invitation, {:link, url}}` without mail,
  the link to show once; `{:error, changeset}` for the day's invitations spent, its error
  on `:email` as an invitation's; `{:error, :has_owner}` for a client that has an owner,
  who invites its people; `{:error, :suspended}` for a suspended client;
  `{:error, :delivery_failed}` for one that could not be delivered, withdrawn as a new one
  is, or `{:error, :delivery_failed_pending}` should the withdrawal fail too;
  `{:error, :unconfirmed}` with mail, for a person whose address is not confirmed, the
  invitation withdrawn as an undelivered one is should mail be set since the new link was
  made; `{:error, :not_found}` for an invitation that is no pending invitation of the
  client's first owner by this operator, one accepted, revoked or expired meanwhile
  included, for an organisation that is no client of the operator, or one marked for
  deletion, and `Apiary.Access`'s answer otherwise.
  """
  @spec renew_owner_invitation(
          Scope.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          (String.t() -> String.t())
        ) ::
          {:ok, %Invitation{}}
          | {:ok, %Invitation{}, {:link, String.t()}}
          | {:error,
             Ecto.Changeset.t()
             | :has_owner
             | :suspended
             | :delivery_failed
             | :delivery_failed_pending
             | :unconfirmed
             | Access.reason()
             | term}
  def renew_owner_invitation(scope, client_id, invitation_id, url_fun),
    do: renew_first_invitation(scope, client_id, invitation_id, url_fun, :owner)

  # Hidden while `ApiaryPro.Flags.operator_infrastructure?/0` is off, so not in the
  # published documentation.
  #
  # renew_admin_invitation/4 makes a new link for the pending invitation `invitation_id`
  # of the first admin of the client `client_id` (`client.renew_admin_invitation`), while
  # the client has no owner and no admin, as `renew_owner_invitation/4` makes
  # one for its first owner. `{:error, :has_admin}` for a client that has one.
  @doc false
  @spec renew_admin_invitation(
          Scope.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          (String.t() -> String.t())
        ) ::
          {:ok, %Invitation{}}
          | {:ok, %Invitation{}, {:link, String.t()}}
          | {:error, Ecto.Changeset.t() | :has_admin | :suspended | Access.reason() | term}
  def renew_admin_invitation(scope, client_id, invitation_id, url_fun),
    do: renew_first_invitation(scope, client_id, invitation_id, url_fun, :admin)

  defp renew_first_invitation(
         %Scope{organisation: %Organisation{id: operator_id} = operator} = scope,
         client_id,
         invitation_id,
         url_fun,
         first
       )
       when is_function(url_fun, 1) do
    with {:ok, id} <- cast(client_id),
         {:ok, invitation_id} <- cast(invitation_id) do
      Repo.transact(fn ->
        # The lock order (docs/access.md): the client's row `FOR SHARE`, which its
        # leaving, its drop and the acceptance of its first owner's invitation wait for,
        # and the organisation the invitation was counted against `FOR NO KEY UPDATE`,
        # the operator's as `invite_owner/4` takes it, or the client's where its trail
        # names none (`Apiary.Organisations.allowance_of/1`), read before any lock; both
        # at one point, in the lock order. The core's renewal then takes that one again,
        # in the same mode, and the invitation.
        allowance_id = allowance_id(id, invitation_id, operator_id)
        held = lock_client_and_allowance(id, allowance_id)

        with %Organisation{deletion_marked_at: nil} = client <- held[id] || {:error, :not_found},
             true <- Tenants.operator_id(client) == operator_id || {:error, :not_found},
             :ok <- Access.authorize(scope, renew_action(first), operator),
             false <- Tenants.suspended?(client) && {:error, :suspended},
             :ok <- nobody_first(client, first),
             %Invitation{} = invitation <-
               Repo.one(
                 from i in Invitation,
                   join: o in OperatorInvitation,
                   on: o.invitation_id == i.id,
                   where: i.id == ^invitation_id and i.organisation_id == ^id,
                   where: o.operator_id == ^operator_id and is_nil(i.accepted_at)
               ) || {:error, :not_found},
             {:ok, workspace} <- invitation_workspace(invitation),
             {:ok, renewed, token} <-
               Organisations.renew_invitation(
                 owner_scope(scope, client, workspace),
                 invitation.id,
                 url_fun,
                 action: renew_action(first)
               ) do
          {:ok, {client, workspace, renewed, token}}
        else
          %Organisation{} -> {:error, :not_found}
          {:error, _reason} = error -> error
        end
      end)
      |> case do
        {:ok, {client, workspace, renewed, token}} ->
          Organisations.send_invitation(
            owner_scope(scope, client, workspace),
            renewed,
            token,
            url_fun
          )

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp renew_first_invitation(_scope, _client_id, _invitation_id, _url_fun, _first),
    do: {:error, :not_found}

  defp invite_action(:owner), do: :"client.invite_owner"
  defp invite_action(:admin), do: :"client.invite_admin"
  defp revoke_action(:owner), do: :"client.revoke_owner_invitation"
  defp revoke_action(:admin), do: :"client.revoke_admin_invitation"
  defp renew_action(:owner), do: :"client.renew_owner_invitation"
  defp renew_action(:admin), do: :"client.renew_admin_invitation"

  # The invitation of a client's first owner: by the operator's person in the client, sent
  # from its workspace, or to the organisation alone while it has none, counted against
  # the operator's allowance, and the operator's row beside it
  # (`ApiaryPro.Operators.OperatorInvitation`), in the caller's transaction, so its person
  # joins as the owner (`ApiaryPro.Invitations`).
  defp invite(scope, operator, client, workspace, attrs, first) do
    with :ok <- Access.authorize(scope, invite_action(first), operator),
         {:ok, invitation, token} <-
           Organisations.insert_invitation(owner_scope(scope, client, workspace), attrs,
             action: invite_action(first),
             allowance: operator
           ),
         {:ok, _operators} <-
           Repo.insert(%OperatorInvitation{
             invitation_id: invitation.id,
             organisation_id: client.id,
             operator_id: operator.id
           }) do
      {:ok, invitation, token}
    end
  end

  # The workspace an invitation was sent from: none for one sent to the organisation alone,
  # while the client had no workspace.
  defp invitation_workspace(%Invitation{workspace_id: nil}), do: {:ok, nil}

  defp invitation_workspace(%Invitation{workspace_id: id}) do
    case Repo.get(Workspace, id) do
      %Workspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :not_found}
    end
  end

  defp owner_scope(scope, client, workspace),
    do: %{Reach.in_client(scope, client) | workspace: workspace}

  # The invitation's refusal of the address, on the form that creates the client.
  defp on_form({:error, %Ecto.Changeset{errors: errors}}, form) do
    {:error,
     %{
       form
       | errors: Keyword.take(errors, [:email]) ++ Keyword.delete(form.errors, :email),
         valid?: false,
         action: :insert
     }}
  end

  defp on_form(result, _form), do: result

  # The client has nobody its first person's invitation would make: no owner, for a first
  # owner; no owner and no admin, for a first admin.
  defp nobody_first(client, :owner),
    do: if(has_level?(client, [:owner]), do: {:error, :has_owner}, else: :ok)

  defp nobody_first(client, :admin),
    do: if(has_level?(client, [:owner, :admin]), do: {:error, :has_admin}, else: :ok)

  defp has_level?(%Organisation{id: id}, levels),
    do: Repo.exists?(from m in Membership, where: m.organisation_id == ^id and m.level in ^levels)

  defp first_workspace(%Organisation{id: id}) do
    Repo.one(
      from w in Workspace,
        where: w.organisation_id == ^id and is_nil(w.deletion_marked_at),
        order_by: [asc: w.name, asc: w.id],
        limit: 1
    )
  end

  ## The instance

  @doc """
  list_organisations/1 is every organisation on the instance, by name, the instance
  organisation first, each with its operator when it is a client, and how many clients it
  has when it is an operator (`instance.read`, an owner's of the instance organisation,
  asked in it), each carrying its tenant (`ApiaryPro.Tenants`): those marked for deletion
  among them, which the page says, and `only_owner?` where the reader is still its only
  owner, as after they created it, for the page to say to invite an owner and leave.
  `{:ok, rows}`; `{:error, :not_found}` anywhere but in the instance organisation, and
  `Apiary.Access`'s answer otherwise.
  """
  @spec list_organisations(Scope.t()) :: {:ok, [instance_row]} | {:error, Access.reason()}
  def list_organisations(%Scope{organisation: %Organisation{} = here} = scope) do
    with :ok <- Access.authorize(scope, :"instance.read", here) do
      clients =
        from c in Tenant,
          where: not is_nil(c.operator_id),
          group_by: c.operator_id,
          select: %{operator_id: c.operator_id, count: count(c.organisation_id)}

      # The organisations the reader owns, and how many owners each has whose account is
      # not deleted: the reader alone, and it is theirs to hand on.
      owners =
        from m in Membership,
          join: u in assoc(m, :user),
          where: m.level == :owner and is_nil(u.deleted_at),
          group_by: m.organisation_id,
          select: %{
            organisation_id: m.organisation_id,
            count: count(m.id),
            reader: filter(count(m.id), m.user_id == ^scope.user.id)
          }

      rows =
        Repo.all(
          from o in Organisation,
            join: t in Tenant,
            on: t.organisation_id == o.id,
            left_join: p in Organisation,
            on: p.id == t.operator_id,
            left_join: c in subquery(clients),
            on: c.operator_id == o.id,
            left_join: w in subquery(owners),
            on: w.organisation_id == o.id,
            order_by: [desc: t.instance_organisation, asc: o.name, asc: o.id],
            select: %{
              organisation: o,
              tenant: t,
              operator: p,
              clients: coalesce(c.count, 0),
              only_owner?:
                not t.instance_organisation and coalesce(w.count, 0) == 1 and
                  coalesce(w.reader, 0) == 1
            }
        )
        |> Enum.map(fn %{organisation: organisation, tenant: tenant} = row ->
          row
          |> Map.delete(:tenant)
          |> Map.put(:organisation, Tenants.put_tenant(organisation, tenant))
        end)

      {:ok, rows}
    end
  end

  def list_organisations(_scope), do: {:error, :not_found}

  @doc """
  create_organisation/2 creates an organisation on the instance, of the kind
  `attrs["kind"]`, `organisation` (`instance.create_organisation`) or `operator`
  (`instance.create_operator`, with `managed_organisations`), named `attrs["name"]`, with
  a slug made from its name and no workspace, for an owner of the instance
  organisation, asked in it. The instance admin who creates it is its first owner, with a
  membership there, who makes its first workspace from the kind cards on its overview
  (`/:org`, `Apiary.Organisations.create_workspace_of_kind/3`), invites its people
  and may leave once another owner is there. Its trail begins with the entry of the
  action, by them, which names their membership; they are told, so their switcher shows
  it.

  `{:ok, %{organisation:, workspace: nil, membership:}}`; `{:error, changeset}`, the changeset
  of `change_client/1`, for a name it refuses, one whose address another organisation or a
  page of Qory Apiary has included (`taken: :refuse`: nothing is numbered); `{:error, :not_found}` for a kind that is
  neither, or anywhere but in the instance organisation, and `Apiary.Access`'s answer
  otherwise.
  """
  @spec create_organisation(Scope.t(), map) ::
          {:ok,
           %{
             organisation: %Organisation{},
             workspace: nil,
             membership: %Membership{}
           }}
          | {:error, Ecto.Changeset.t() | Access.reason()}
  def create_organisation(%Scope{organisation: %Organisation{}} = scope, attrs) do
    form = change_client(attrs)

    with {:ok, kind} <- kind(attrs["kind"] || attrs[:kind]) do
      action =
        if kind == :operator,
          do: :"instance.create_operator",
          else: :"instance.create_organisation"

      # The creation asks `Apiary.Access` before it checks the name.
      Ecto.Multi.new()
      |> Ecto.Multi.run(:asked, fn _repo, _changes ->
        with :ok <- Access.authorize(scope, action, scope.organisation), do: {:ok, nil}
      end)
      |> Ecto.Multi.put(:user, scope.user)
      |> Organisations.build_organisation(
        name: Ecto.Changeset.get_field(form, :name),
        action: action,
        taken: :refuse,
        how: {:kind, kind},
        workspace: false,
        scope: &as_the_instance_in(scope, &1.organisation)
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{created: %{membership: membership} = created}} ->
          Organisations.broadcast_membership_changes([membership])
          {:ok, created}

        refused ->
          refusal(refused, form)
      end
    end
  end

  def create_organisation(_scope, _attrs), do: {:error, :not_found}

  @doc """
  change_kind/3 makes the organisation `organisation_id` of the kind `kind`
  (`instance.change_kind`, an owner's of the instance organisation, asked in it, with
  `managed_organisations`): an organisation an operator, unless it is a client of one,
  `{:error, :client}`; an operator an organisation, once it has no clients, marked for
  deletion or not, `{:error, :has_clients}`. The database refuses either too. The instance
  organisation is changed as any other: made an operator, its people see its Clients page
  and its owners and admins create clients from it; made an organisation again once it has
  none. The organisation's row is locked `FOR UPDATE` while its tenant is changed, so a
  client created at once is either seen or refused by the database. An entry of
  `instance.change_kind` in the changed organisation's trail, by the instance admin, with
  the kind before and after; nothing changes, and nothing is recorded, for the kind it
  has already.

  `{:ok, organisation}`; `{:error, :not_found}` for an organisation that is not there or
  is marked for deletion, or a kind that is neither, and `Apiary.Access`'s answer.
  """
  @spec change_kind(Scope.t(), String.t(), Tenants.kind() | String.t()) ::
          {:ok, %Organisation{}}
          | {:error, :client | :has_clients | Ecto.Changeset.t() | Access.reason()}
  def change_kind(%Scope{} = scope, organisation_id, kind) do
    with {:ok, kind} <- kind(kind),
         {:ok, id} <- cast(organisation_id) do
      Repo.transact(fn ->
        with %Organisation{} = organisation <-
               Tenants.lock_organisation(id, "FOR UPDATE") || {:error, :not_found},
             :ok <- Access.authorize(scope, :"instance.change_kind", organisation) do
          was = Tenants.kind(organisation)

          cond do
            was == kind ->
              {:ok, organisation}

            kind == :operator and Tenants.client?(organisation) ->
              {:error, :client}

            kind == :organisation and has_clients?(organisation) ->
              {:error, :has_clients}

            true ->
              had = ApiaryPro.Features.of(organisation)

              with {:ok, tenant} <-
                     organisation
                     |> Tenants.tenant()
                     |> Tenants.kind_changeset(kind)
                     |> Repo.insert_or_update(),
                   changed = Tenants.put_tenant(organisation, tenant),
                   {:ok, _features} <- Grants.written_out(changed, kind, features: had),
                   {:ok, _withdrawn} <- withdraw_offers(changed, scope),
                   {:ok, _entry} <-
                     Audit.record(
                       Repo,
                       as_the_instance_in(scope, changed),
                       :"instance.change_kind",
                       changed,
                       %{before: %{kind: was}, after: %{kind: kind}}
                     ) do
                {:ok, changed}
              end
          end
        end
      end)
      |> tap(fn
        # Its people's open pages load their scope again: the Clients entry comes or goes.
        {:ok, changed} -> tell_the_people_of(changed)
        _refused -> :ok
      end)
    end
  end

  # Hidden while `ApiaryPro.Flags.operator_infrastructure?/0` is off, so not in the
  # published documentation.
  #
  # set_model_chain/3 sets whose model providers the runs of the client `client_id` of the
  # scope's organisation, an operator, use (`client.set_model_chain`, an owner's or an
  # admin's of the operator): `:organisation`, the client's, or `:operator`, the operator's
  # (`ApiaryPro.Tenants.model_chain/1`). The client's row is locked `FOR NO KEY UPDATE`
  # and the operator's `FOR SHARE`, as a drop locks them, at one point, in the lock order.
  # An entry of `client.set_model_chain` in the operator's trail, by the person who set it,
  # with the client's id and the switch before and after; nothing changes, and nothing is
  # recorded, for the value it has already. The client's and the operator's people are told
  # once it is written, so their pages load their scope again. Once a changed value has
  # committed, the client's waiting runs get the model providers of the new chain
  # (`Apiary.Dispatches.refresh_model_providers/1`).
  #
  # `{:ok, client}`; `{:error, :suspended}` for a suspended client; `{:error, :busy}` for
  # a deadlock Postgres broke; `{:error, :not_found}` for an organisation that is no
  # client of the operator, one marked for deletion, or a value that is neither, and
  # `Apiary.Access`'s answer otherwise; a person of the client has no scope in the
  # operator, and is not found there.
  @doc false
  @spec set_model_chain(Scope.t(), Ecto.UUID.t(), Tenant.model_chain() | String.t()) ::
          {:ok, %Organisation{}} | {:error, :suspended | :busy | Access.reason() | term}
  def set_model_chain(
        %Scope{organisation: %Organisation{id: operator_id}} = scope,
        client_id,
        chain
      ) do
    with {:ok, chain} <- model_chain(chain),
         {:ok, id} <- cast(client_id) do
      Repo.transact(fn ->
        with {:ok, held} <- lock_client_and_operator(id, operator_id),
             %Organisation{deletion_marked_at: nil} = client <- held[id] || {:error, :not_found},
             true <- Tenants.operator_id(client) == operator_id || {:error, :not_found},
             %Organisation{} = operator <- held[operator_id] || {:error, :not_found},
             :ok <- Access.authorize(scope, :"client.set_model_chain", operator),
             false <- Tenants.suspended?(client) && {:error, :suspended} do
          write_model_chain(scope, client, operator, chain)
        else
          %Organisation{} -> {:error, :not_found}
          {:error, _reason} = error -> error
        end
      end)
      |> case do
        {:ok, {client, changed?}} ->
          if changed? do
            :ok = Apiary.Dispatches.refresh_model_providers({:organisation, client.id})
          end

          tell_people_of([client.id, operator_id])
          {:ok, client}

        refused ->
          refused
      end
    end
  end

  def set_model_chain(_scope, _client_id, _chain), do: {:error, :not_found}

  # `{:ok, {client, changed?}}`: the client as written, and whether its chain changed.
  defp write_model_chain(scope, client, operator, chain) do
    was = Tenants.model_chain(client)

    if was == chain do
      {:ok, {client, false}}
    else
      with {:ok, tenant} <-
             client |> Tenants.tenant() |> Tenants.model_chain_changeset(chain) |> Repo.update(),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"client.set_model_chain", operator, %{
               details: %{organisation_id: client.id},
               before: %{model_chain: was},
               after: %{model_chain: chain}
             }) do
        {:ok, {Tenants.put_tenant(client, tenant), true}}
      end
    end
  end

  @doc """
  has_clients?/1 says whether an organisation is the operator of any client, one marked
  for deletion included, as the database has it now.
  """
  @spec has_clients?(%Organisation{}) :: boolean
  def has_clients?(%Organisation{id: id}),
    do: Repo.exists?(from t in Tenant, where: t.operator_id == ^id)

  ## Helpers

  # An operator made an organisation takes on no client: the offers to it are withdrawn.
  defp withdraw_offers(%Organisation{} = organisation, scope) do
    if Tenants.operator?(organisation),
      do: {:ok, 0},
      else: Transfers.withdraw_offers_to(organisation, "operator_made_organisation", scope)
  end

  # The client's row `FOR SHARE` and the allowance's `FOR NO KEY UPDATE`, or the client's
  # alone `FOR NO KEY UPDATE` where it is the allowance, at one point, in the lock order:
  # the organisations held, by their ids.
  defp lock_client_and_allowance(client_id, allowance_id) do
    Tenants.lock_organisations!(Enum.reject([client_id, allowance_id], &is_nil/1), fn
      ^allowance_id -> :no_key_update
      _client -> :share
    end)
  end

  # The organisation the pending invitation `invitation_id` of the client's first person,
  # by the operator, was counted against, as the core's renewal finds it
  # (`Apiary.Organisations.allowance_of/1`), read without a lock: its id, or nil for no
  # such invitation, or one whose organisation is gone, which the renewal refuses after.
  defp allowance_id(client_id, invitation_id, operator_id) do
    with %Invitation{} = invitation <-
           Repo.one(
             from i in Invitation,
               join: o in OperatorInvitation,
               on: o.invitation_id == i.id,
               where: i.id == ^invitation_id and i.organisation_id == ^client_id,
               where: o.operator_id == ^operator_id
           ),
         {:ok, %Organisation{id: id}} <- Organisations.allowance_of(invitation) do
      id
    else
      _none -> nil
    end
  end

  # The client's row `FOR NO KEY UPDATE` and the operator's `FOR SHARE`, at one point, in
  # the lock order: the organisations held, by their ids, or `{:error, :busy}`.
  defp lock_client_and_operator(client_id, operator_id) do
    Tenants.lock_organisations([client_id, operator_id], fn
      ^client_id -> :no_key_update
      _operator -> :share
    end)
  end

  defp tell_people_of(organisation_ids) do
    Repo.all(from m in Membership, where: m.organisation_id in ^organisation_ids)
    |> Organisations.broadcast_membership_changes()
  end

  defp lock_operator(%Organisation{id: id}) do
    Repo.one(from o in Organisation, where: o.id == ^id, select: o.id, lock: "FOR NO KEY UPDATE")
    :ok
  end

  # What a creation's transaction refused, as the form says it: the name the form refuses,
  # as the form says it; one the database refused besides, on the form's name; anything
  # else of the organisation's, one sentence on the name; and `Apiary.Access`'s answer.
  defp refusal({:error, :asked, reason, _changes}, _form), do: {:error, reason}

  defp refusal({:error, _step, %Ecto.Changeset{}, _changes}, form) when not form.valid?,
    do: {:error, Map.put(form, :action, :insert)}

  defp refusal({:error, _step, %Ecto.Changeset{errors: errors}, _changes}, form) do
    case Keyword.take(errors, [:name]) do
      [] ->
        {:error, not_created(form)}

      name_errors ->
        {:error, %{form | errors: name_errors ++ form.errors, valid?: false, action: :insert}}
    end
  end

  defp refusal({:error, _step, reason, _changes}, _form), do: {:error, reason}

  defp not_created(form) do
    form
    |> Ecto.Changeset.add_error(
      :name,
      dgettext_noop("errors", "could not be created just now; please try again")
    )
    |> Map.put(:action, :insert)
  end

  # The scope's person, acting in `organisation`: an entry of a change the instance or an
  # operator makes to another organisation than the one the scope is in is that
  # organisation's.
  defp in_organisation(scope, organisation), do: Scope.in_organisation(scope, organisation)

  # An instance admin, acting in another organisation than the instance organisation: its
  # trail names them, and keeps nothing of where they were, their address or their client,
  # which belong to the instance, not to that organisation. A worker stays. In the
  # instance organisation itself, whose kind they change as one of its owners, the entry
  # is in that organisation's trail, and keeps where they acted from, as any change there
  # does.
  defp as_the_instance_in(
         %Scope{organisation: %Organisation{id: id}} = scope,
         %Organisation{id: id} = organisation
       ),
       do: in_organisation(scope, organisation)

  defp as_the_instance_in(%Scope{} = scope, %Organisation{} = organisation) do
    origin =
      case scope.origin do
        %{worker: _worker} = origin -> origin
        _request -> nil
      end

    %{in_organisation(scope, organisation) | origin: origin}
  end

  defp tell_the_people_of(%Organisation{id: operator_id}) do
    Repo.all(from m in Membership, where: m.organisation_id == ^operator_id)
    |> Organisations.broadcast_membership_changes()
  end

  defp kind(kind) when kind in [:organisation, :operator], do: {:ok, kind}
  defp kind("organisation"), do: {:ok, :organisation}
  defp kind("operator"), do: {:ok, :operator}
  defp kind(_other), do: {:error, :not_found}

  defp model_chain(chain) when chain in [:organisation, :operator], do: {:ok, chain}
  defp model_chain("organisation"), do: {:ok, :organisation}
  defp model_chain("operator"), do: {:ok, :operator}
  defp model_chain(_other), do: {:error, :not_found}

  defp cast(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end
end
