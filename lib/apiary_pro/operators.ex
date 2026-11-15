defmodule ApiaryPro.Operators do
  @moduledoc """
  Operators, and the instance actions of the instance organisation's owners.

  An operator operates workspaces of other organisations (`ApiaryPro.WorkspaceOperators`):
  its people reach those workspaces (`ApiaryPro.Reach`).

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

  Every change is an audit entry, written in its transaction (`Apiary.Audit`): an
  organisation's creation by the instance and a change of kind
  (`instance.create_organisation`, `instance.create_operator`, `instance.change_kind`) are
  entries of the organisation created or changed, whose trail they begin or continue, by
  the person who acted.
  """

  use Gettext, backend: ApiaryProWeb.Gettext
  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Organisation}
  alias ApiaryPro.{Grants, Tenants, WorkspaceOperators}
  alias ApiaryPro.Tenants.Tenant

  @typedoc "An organisation on Instance settings › Organisations."
  @type instance_row :: %{
          organisation: %Organisation{},
          operator: %Organisation{} | nil,
          clients: non_neg_integer,
          only_owner?: boolean
        }

  @doc """
  change_organisation/1 is the changeset of the form that names a new organisation on
  Instance settings › Organisations: its name, checked as an organisation's name is.
  """
  @spec change_organisation(map) :: Ecto.Changeset.t()
  def change_organisation(attrs \\ %{}), do: Organisation.changeset(%Organisation{}, attrs)

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
  of `change_organisation/1`, for a name it refuses, one whose address another organisation or a
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
    form = change_organisation(attrs)

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
  `{:error, :client}`, or a workspace of it has an operator,
  `{:error, :has_operated_workspaces}`; an operator an organisation, once it has no
  clients, marked for deletion or not, `{:error, :has_clients}`, and operates no
  workspace, one marked for deletion included, `{:error, :has_operated_workspaces}`.
  A database constraint holds each of these but the operated workspaces of an
  organisation made an operator. The instance organisation is changed as any other. The
  organisation's row is locked `FOR UPDATE` while its tenant is changed. An entry of
  `instance.change_kind` in the changed organisation's trail, by the instance admin, with
  the kind before and after; nothing changes, and nothing is recorded, for the kind it
  has already.

  `{:ok, organisation}`; `{:error, :not_found}` for an organisation that is not there or
  is marked for deletion, or a kind that is neither, and `Apiary.Access`'s answer.
  """
  @spec change_kind(Scope.t(), String.t(), Tenants.kind() | String.t()) ::
          {:ok, %Organisation{}}
          | {:error,
             :client
             | :has_clients
             | :has_operated_workspaces
             | Ecto.Changeset.t()
             | Access.reason()}
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

            kind == :operator and WorkspaceOperators.has_operated_workspaces?(organisation) ->
              {:error, :has_operated_workspaces}

            kind == :organisation and has_clients?(organisation) ->
              {:error, :has_clients}

            kind == :organisation and WorkspaceOperators.operates_workspaces?(organisation) ->
              {:error, :has_operated_workspaces}

            true ->
              had = ApiaryPro.Features.of(organisation)

              with {:ok, tenant} <-
                     organisation
                     |> Tenants.tenant()
                     |> Tenants.kind_changeset(kind)
                     |> Repo.insert_or_update(),
                   changed = Tenants.put_tenant(organisation, tenant),
                   {:ok, _features} <- Grants.written_out(changed, kind, features: had),
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
        # Its people's open pages load their scope again, with the features of its kind.
        {:ok, changed} -> tell_the_people_of(changed)
        _refused -> :ok
      end)
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

  defp cast(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end
end
