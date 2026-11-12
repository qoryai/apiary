defmodule ApiaryPro.Grants do
  @moduledoc """
  Writing what each link below the instance has (`ApiaryPro.Features`, Below the instance):
  the grants, each asked of `Apiary.Access` and each an audit entry.

  - `set_organisation/3` (`instance.grant_features`, an instance admin's, on the instance
    page): what an operator is granted, opt-in, or what an organisation with no operator
    keeps, opt-out, of the instance's. Never a client, whose operator grants it, nor the
    instance organisation, which has everything the instance has.
  - `set_client/3` (`client.grant_features`, an owner's of the operator, on its Clients
    page): what a client is granted, of the operator's features; never `managed_organisations`.

  A workspace has its organisation's features: no grant names a workspace.

  A grant above what the granter has is refused at write, `{:error, :above}`, and so is a
  feature without the features it needs, `{:error, :needs}`. When a link narrows later,
  everything below is clipped where it is read (`ApiaryPro.Features.of/2`), with no
  rewrite.

  The grants follow an organisation when it changes where it sits, in the transaction of
  that change (`written_out/2`): made an operator, it is granted what it had, and from then
  only a grant changes it; made an organisation again, it keeps what it had, opt-out; a new
  operator is granted what the instance has; a new client is granted what its operator
  has; a client its operator drops follows the instance.

  **Race safety.** A write asks `Apiary.Access` first, then locks the rows it narrows
  `FOR NO KEY UPDATE`, in the lock order of docs/access.md, at one point
  (`ApiaryPro.Tenants.lock_organisations/2`): an operator's clients, then the operator;
  a client, then its operator `FOR SHARE`. It asks again once they are held, so a
  suspension that locked them first is seen. A write in flight holds them `FOR SHARE` and
  is waited for; a row that only names them, `FOR KEY SHARE`, is not. A change that holds
  them while it is written (`Apiary.Access.reload/2` with `lock: :share`, which reads the
  features after its locks) is written first, and one asked after waits and then sees the
  narrower features. A grant to a client and a grant to its operator lock the client in
  the same order, the client first for the operator's. A grant takes organisation rows
  only, and renders nothing: the organisation's policy holds above its workspaces whatever
  it is granted (`ApiaryPro.OrganisationPolicy`). A grant that changes something tells the
  people it reaches, whose open pages load their scope again.

  A write changes only the features a page shows (`shown/1`): a grant of a feature not
  shown, one the granter lacks or one not built, stays as stored, and an operator keeps
  `managed_organisations`, which it loses only by being made an organisation. A suspended
  organisation or client is granted nothing, `{:error, :suspended}`. The entry records the
  built features a grant can name, before and after.
  """

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Features, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.{Flags, Reach, Tenants}
  alias ApiaryPro.Grants.Grant
  alias ApiaryPro.Tenants.Tenant

  # How many times a change of an operator's features takes its clients and itself afresh,
  # should a client come between the read of its clients and their lock.
  @client_attempts 3

  @typedoc "A feature, or its name, as a form sends it."
  @type feature_name :: Features.feature() | String.t()

  ## Reading, for the pages

  @doc """
  offered/1 is the features a grant or a narrowing of `organisation` may name, in the
  order of `Apiary.Features.all/0`: the instance's, for an operator or an organisation with
  no operator; its operator's but `managed_organisations`, for a client. Never one only
  the instance switches (`ApiaryPro.Features.instance_switched/0`), which no grant names.
  """
  @spec offered(%Organisation{}) :: [Features.feature()]
  def offered(%Organisation{} = organisation) do
    above =
      case Tenants.operator_id(organisation) do
        nil -> Features.enabled()
        operator_id -> ApiaryPro.Features.of_organisation(operator_id) -- [:managed_organisations]
      end

    above -- ApiaryPro.Features.instance_switched()
  end

  @doc """
  shown/1 is the features a page grants or takes away of `organisation`, and the only ones
  a write changes: those of `offered/1` that are built (`Apiary.Features.built/0`), and
  never an operator's `managed_organisations`, which it loses only by being made an
  organisation. A grant of a feature not shown, one the granter lacks or one not built, is
  kept as it is stored.
  """
  @spec shown(%Organisation{}) :: [Features.name()]
  def shown(%Organisation{} = organisation) do
    shown = Enum.filter(offered(organisation), &(&1 in Features.built()))
    shown = if Tenants.operator?(organisation), do: shown -- [:managed_organisations], else: shown
    shown ++ parts_shown(organisation, shown)
  end

  # While features are shown by who asks (`ApiaryPro.Flags.feature_visibility?/0`), a page
  # shows or hides the parts of the features it shows (`Apiary.Features.parts/0`), the
  # run's Terminal under Runs, and a write changes them; for a client, only those its
  # operator is shown, as it shows only the features the operator is shown; and only
  # those a grant can name (`ApiaryPro.Grants.Grant`). A part is
  # shown unless a row of the organisation hides it, whatever its kind, so its box is
  # checked where none does (`parts_kept/1`). None while the switch is off: a form that
  # names a part then names a feature the granter lacks, `{:error, :above}`.
  #
  # A client's page shows the nodes as well, a part of no feature, while both switches
  # are on (`ApiaryPro.Features.client_parts/1`), whatever the features it shows: an
  # operator is never hidden them, so its page offers them for every client. No other page
  # offers them.
  defp parts_shown(organisation, shown) do
    if Flags.feature_visibility?() do
      above =
        case Tenants.operator_id(organisation) do
          nil -> []
          operator_id -> ApiaryPro.Features.hidden_parts([operator_id])
        end

      client_parts = ApiaryPro.Features.client_parts(organisation)

      for part <- Features.parts(),
          part in Ecto.Enum.values(Grant, :feature),
          (Features.feature_of(part) in shown and part not in above) or part in client_parts,
          do: part
    else
      []
    end
  end

  # parts_kept/1 is the parts of `shown/1` that no row of `organisation` hides: the boxes
  # a page checks for them. None while the switch is off.
  @doc false
  @spec parts_kept(%Organisation{}) :: [Features.part()]
  def parts_kept(%Organisation{} = organisation) do
    hidden = ApiaryPro.Features.hidden_parts([organisation.id])
    Enum.filter(shown(organisation), &(&1 in Features.parts() and &1 not in hidden))
  end

  ## Writing

  @doc """
  set_organisation/3 sets the features of the organisation `organisation_id` to
  `features`, of the instance's (`instance.grant_features`, an instance admin's, asked in
  the instance organisation): an operator is granted them, an organisation with no
  operator keeps them and has the others taken away. An entry of `instance.grant_features`
  in the organisation's trail, with its features before and after; nothing changes and
  nothing is recorded when they are the same.

  `{:ok, features}`; `{:error, :client}` for a client, whose operator grants it;
  `{:error, :above}` for a feature the instance does not have, or an operator's
  `managed_organisations`; `{:error, :needs}` for one without the features it needs;
  `{:error, :suspended}` for a suspended organisation; `{:error, :changed}` for one whose
  kind changed since the form was read; `{:error, :forbidden}` for the instance
  organisation, which has everything the instance has; `{:error, :not_found}` for one not
  there or marked for deletion; `{:error, :busy}` for a change that came at the same
  moment, to try again, and `Apiary.Access`'s answer otherwise.
  """
  @spec set_organisation(Scope.t(), Ecto.UUID.t(), [feature_name]) ::
          {:ok, [Features.feature()]}
          | {:error, :client | :above | :needs | :busy | Access.reason() | term}
  def set_organisation(%Scope{} = scope, organisation_id, features) do
    with {:ok, id} <- cast(organisation_id),
         {:ok, features} <- names(features) do
      Repo.transact(fn ->
        # Asked first, then an operator's clients and the organisation itself locked at
        # one point, in the lock order: the order an invitation in a client and a change
        # asked in one take them. What was asked of is read again under the lock.
        with %Organisation{} = seen <- get_organisation(id) || {:error, :not_found},
             :ok <- Access.authorize(scope, :"instance.grant_features", seen),
             {:ok, held, _clients} <- lock_with_clients(id, @client_attempts),
             %Organisation{} = organisation <- held[id] || {:error, :not_found},
             :ok <- Access.check(scope, :"instance.grant_features", organisation),
             # A form of a kind it no longer has: an operator's features are not an
             # organisation's, nor the other way round.
             true <- Tenants.kind(organisation) == Tenants.kind(seen) || {:error, :changed},
             true <- not Tenants.client?(organisation) || {:error, :client},
             false <- Tenants.suspended?(organisation) && {:error, :suspended},
             shown = shown(organisation),
             :ok <- within(features, shown) do
          write(
            organisation,
            features,
            shown,
            scope |> Scope.in_organisation(organisation) |> Scope.put_origin(nil),
            :"instance.grant_features",
            organisation
          )
        end
      end)
      |> tell(id)
    end
  end

  @doc """
  set_client/3 sets the features of the client `client_id` of the scope's organisation, an
  operator, to `features`, of the operator's features but `managed_organisations`
  (`client.grant_features`, an owner's of the operator): the client is granted them. An
  entry of `client.grant_features` in the client's trail; none when nothing changes.

  `{:ok, features}`; `{:error, :above}` for a feature the operator does not have, or
  `managed_organisations`; `{:error, :needs}`; `{:error, :suspended}` for a suspended
  client; `{:error, :not_found}` for an organisation that is not its client or is marked
  for deletion; `{:error, :busy}` for a change that came at the same moment, to try again,
  and `Apiary.Access`'s answer otherwise.
  """
  @spec set_client(Scope.t(), Ecto.UUID.t(), [feature_name]) ::
          {:ok, [Features.feature()]}
          | {:error, :above | :needs | :busy | Access.reason() | term}
  def set_client(
        %Scope{organisation: %Organisation{id: operator_id} = operator} = scope,
        client_id,
        features
      ) do
    with {:ok, id} <- cast(client_id),
         {:ok, features} <- names(features) do
      Repo.transact(fn ->
        # Asked first, then the client `FOR NO KEY UPDATE` and its operator `FOR SHARE`,
        # whose features the client's are clipped by, at one point, in the lock order.
        # Asked again once the operator is held, over the scope read again: a suspension
        # of the operator, which locks it for update, that came while the grant waited is
        # seen, and one after waits for the grant.
        with :ok <- Access.authorize(scope, :"client.grant_features", operator),
             {:ok, held} <-
               Tenants.lock_organisations([id, operator_id], fn
                 ^id -> :no_key_update
                 _operator -> :share
               end),
             %Organisation{} = operator <- held[operator_id] || {:error, :not_found},
             :ok <- Access.authorize(scope, :"client.grant_features", operator),
             %Organisation{deletion_marked_at: nil} = client <- held[id] || {:error, :not_found},
             true <- Tenants.operator_id(client) == operator_id || {:error, :not_found},
             false <- Tenants.suspended?(client) && {:error, :suspended},
             shown = shown(client),
             :ok <- within(features, shown) do
          write(
            client,
            features,
            shown,
            Reach.in_client(scope, client),
            :"client.grant_features",
            client
          )
        else
          %Organisation{} -> {:error, :not_found}
          {:error, _reason} = error -> error
        end
      end)
      |> tell(id)
    end
  end

  def set_client(_scope, _client_id, _features), do: {:error, :not_found}

  ## When an organisation changes where it sits

  @doc """
  written_out/2 writes the grants an organisation has when it changes where it sits, in
  the transaction of that change, which asked `Apiary.Access` and records it: `:operator`,
  made an operator, is granted what it has (`features:` what it had before, as an
  organisation) or, for a new one, what the instance has of the features a grant can name,
  and `managed_organisations` always, so a feature the instance gains reaches it once
  granted; `:organisation`, made an organisation again, keeps what it had and has the rest
  taken away; `{:client, operator}`, a new client, is granted what its operator has;
  `:left`, a client its operator dropped, follows the instance. Only the features a grant
  can name are written (`ApiaryPro.Grants.Grant`). The organisation's rows are replaced.
  `{:ok, features}`: what its rows grant, for an operator, a new client and a client its
  operator dropped; the instance's features but what its rows take away, for an
  organisation made one again; either without a feature whose needs are not among them
  (`Apiary.Features.closed/1`). Not what it is shown, which `ApiaryPro.Features.of/2`
  answers.
  """
  @spec written_out(
          %Organisation{},
          :operator | :organisation | :left | {:client, %Organisation{}},
          keyword
        ) ::
          {:ok, [Features.feature()]}
  def written_out(organisation, where, opts \\ [])

  def written_out(%Organisation{} = organisation, :operator, opts) do
    features = Keyword.get(opts, :features, Features.enabled())

    # The built ones, opt-in ones included: a feature the instance gains reaches no operator
    # until it is granted.
    built = Features.built() ++ Features.opt_in()

    replace(
      organisation,
      Enum.filter(Enum.uniq(features ++ [:managed_organisations]), &(&1 in built)),
      true,
      :keep_parts
    )
  end

  def written_out(%Organisation{} = organisation, :organisation, opts) do
    had = Keyword.get(opts, :features, [])
    replace(organisation, Features.enabled() -- had, false, :keep_parts)
  end

  def written_out(%Organisation{} = organisation, {:client, %Organisation{} = operator}, _opts) do
    replace(organisation, ApiaryPro.Features.of(operator) -- [:managed_organisations], true)
  end

  def written_out(%Organisation{} = organisation, :left, _opts),
    do: replace(organisation, [], true)

  ## Helpers

  # Once a change that wrote an entry is committed, the people it reaches are told, so their open pages load
  # their scope again, with its features (`ApiaryWeb.UserAuth.reload_scope/1`): the
  # organisation's, its operator's, who reach it, and an operator's clients'.
  defp tell({:ok, {:unchanged, features}}, _organisation_id), do: {:ok, features}

  defp tell({:ok, {:changed, features}}, organisation_id) do
    related =
      from t in Tenant,
        where: t.organisation_id == ^organisation_id or t.operator_id == ^organisation_id,
        select: %{id: t.organisation_id, operator_id: t.operator_id}

    ids =
      related
      |> Repo.all()
      |> Enum.flat_map(&[&1.id, &1.operator_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Repo.all(from m in Apiary.Organisations.Membership, where: m.organisation_id in ^ids)
    |> Apiary.Organisations.broadcast_membership_changes()

    {:ok, features}
  end

  defp tell(result, _organisation_id), do: result

  # The organisation's grant rows replaced: `granted` for each feature named that a grant
  # can name. One its schema has no value for, such as the core's `secrets`, has no
  # row to hold it and is not written.
  #
  # The rows that hide a part, of a feature or the nodes (`ApiaryPro.Features.hidden/1`),
  # stay where it changes kind, `:keep_parts`, as it keeps what it had: its people are
  # hidden the same parts. A new client, or a client its operator drops, has them deleted
  # with the rest: it is shown every part of what it is shown, as the level above shows
  # them.
  defp replace(%Organisation{id: id}, features, granted, parts \\ :delete_parts) do
    names = Ecto.Enum.values(Grant, :feature)
    features = Enum.filter(features, &(&1 in names))

    case parts do
      :keep_parts ->
        kept = Enum.filter(Features.parts(), &(&1 in names))

        Repo.delete_all(
          from g in Grant, where: g.organisation_id == ^id and g.feature not in ^kept
        )

      :delete_parts ->
        Repo.delete_all(from g in Grant, where: g.organisation_id == ^id)
    end

    insert_rows(id, features, granted)
    {:ok, Features.closed(if(granted, do: features, else: Features.enabled() -- features))}
  end

  # The rows of one link for the features `shown`, which the form names or leaves out: an
  # operator's and a client's are granted what it names, an organisation with no operator
  # has what it leaves out taken away. The rows of the features not shown stay as they are
  # stored. The entry records the built features before and after.
  #
  # A part the page shows (`shown/1`) is hidden by a row, `granted` false, where the form
  # leaves its box out, and shown where it names it, for every kind of organisation: a
  # part is shown wherever its feature is, but where a row hides it. A change of parts
  # alone is a change: it is recorded, and its people told.
  defp write(organisation, features, shown, record_scope, action, subject) do
    was = state(organisation)
    {shown_parts, shown} = Enum.split_with(shown, &(&1 in Features.parts()))
    named = Enum.filter(features, &(&1 in shown))

    {granted, rows} =
      if opt_in?(organisation),
        do: {true, named},
        else: {false, shown -- named}

    Repo.delete_all(
      from g in Grant,
        where: g.organisation_id == ^organisation.id and g.feature in ^(shown ++ shown_parts)
    )

    insert_rows(organisation.id, rows, granted)
    insert_rows(organisation.id, shown_parts -- features, false)

    {now, _parts} = is = state(organisation)

    if is == was do
      {:ok, {:unchanged, now}}
    else
      with {:ok, _entry} <-
             Audit.record(
               Repo,
               record_scope,
               action,
               subject,
               marked(%{before: %{features: listed(was)}, after: %{features: listed(is)}})
             ),
           do: {:ok, {:changed, now}}
    end
  end

  # What the organisation is shown, as a write compares it: its features (`of/2`) and,
  # while features are shown by who asks, the parts of them it is shown.
  defp state(organisation) do
    features = ApiaryPro.Features.of(organisation)

    if Flags.feature_visibility?(),
      do: {features, ApiaryPro.Features.parts_of(organisation, features)},
      else: {features, []}
  end

  # The built features an entry records, but the ones only the instance switches
  # (`ApiaryPro.Features.instance_switched/0`), each followed by the parts of it shown,
  # which only an entry written while features are shown by who asks names; then the parts
  # of no feature shown, the nodes, which only a client's entry names, while both switches
  # are on.
  defp listed({features, parts}) do
    recorded = Features.built() -- ApiaryPro.Features.instance_switched()

    of_features =
      for feature <- features,
          feature in recorded,
          name <- [feature | Enum.filter(parts, &(Features.feature_of(&1) == feature))],
          do: name

    of_features ++ Enum.filter(parts, &is_nil(Features.feature_of(&1)))
  end

  # While features are shown by who asks (`ApiaryPro.Flags.feature_visibility?/0`), the
  # entry says the change is one of what is shown, `shown: true` in its details, and the
  # Activity page says it in those words (`ApiaryProWeb.ActivityDescriber`). An entry
  # written before, or with the switch off, has none and keeps its words.
  defp marked(data) do
    if ApiaryPro.Flags.feature_visibility?(),
      do: Map.put(data, :details, %{shown: true}),
      else: data
  end

  defp opt_in?(%Organisation{} = organisation),
    do: Tenants.operator?(organisation) or Tenants.client?(organisation)

  defp insert_rows(_organisation_id, [], _granted), do: :ok

  defp insert_rows(organisation_id, features, granted) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Grant,
      for feature <- Enum.uniq(features) do
        %{
          id: Ecto.UUID.generate(),
          organisation_id: organisation_id,
          feature: feature,
          granted: granted,
          inserted_at: now
        }
      end
    )

    :ok
  end

  # The organisation, carrying its tenant.
  defp get_organisation(id) do
    case Repo.get(Organisation, id) do
      nil -> nil
      organisation -> Tenants.put(organisation)
    end
  end

  # The organisation and an operator's clients, whose features are clipped by the
  # operator's, `FOR NO KEY UPDATE`, in one statement in the lock order
  # (`ApiaryPro.Tenants.lock_organisations/2`): the clients first, then the operator. A
  # change in a client that holds the client alone while it reads the client's features,
  # as a new workspace in it does, waits for the grant, or is waited for, and the two
  # never wait on each other. A client stays the operator's while its row is held: a
  # client's drop locks it `FOR NO KEY UPDATE` first, and a new client locks the operator
  # first. The clients are read again once the rows are held: a client that came between
  # the read and the lock means a set taken stale, which is let go of, rolling back to a
  # savepoint, and taken afresh, `attempts` times in all, and `{:error, :busy}` after, as
  # for a deadlock that outlived the core's one retry. `{:ok, held, clients}`, the
  # organisations held by their ids and the clients the operator has now, in the order of
  # their ids.
  defp lock_with_clients(id, attempts) do
    clients = clients_of(id)
    Repo.query!("SAVEPOINT pro_grants_lock_with_clients")

    with {:ok, held} <- Tenants.lock_organisations([id | clients], :no_key_update),
         now = clients_of(id),
         true <- now -- clients == [] || :stale do
      Repo.query!("RELEASE SAVEPOINT pro_grants_lock_with_clients")
      {:ok, held, now}
    else
      failed ->
        Repo.query!("ROLLBACK TO SAVEPOINT pro_grants_lock_with_clients")
        Repo.query!("RELEASE SAVEPOINT pro_grants_lock_with_clients")

        if failed == :stale and attempts > 1,
          do: lock_with_clients(id, attempts - 1),
          else: {:error, :busy}
    end
  end

  defp clients_of(id),
    do:
      Repo.all(
        from t in Tenant,
          where: t.operator_id == ^id,
          order_by: t.organisation_id,
          select: t.organisation_id
      )

  # A part needs no feature beyond the one it is a part of: a part of a feature the form
  # leaves out is hidden with it, whatever its box says. A feature only the instance
  # switches (`ApiaryPro.Features.instance_switched/0`), which no form names, counts where
  # the instance has it: `organisation_variables` needs `secrets`, which has no box.
  defp within(names, offered) do
    features = Enum.reject(names, &(&1 in Features.parts()))
    switched = Enum.filter(Features.enabled(), &(&1 in ApiaryPro.Features.instance_switched()))
    kept = kept(features ++ switched)

    cond do
      Enum.any?(names, &(&1 not in offered)) ->
        {:error, :above}

      Enum.any?(features, &(&1 not in kept)) ->
        {:error, :needs}

      true ->
        :ok
    end
  end

  # The features kept only with the features they need, until none is left without one:
  # `Apiary.Features.closed/1` takes one pass.
  defp kept(features) do
    present = Enum.filter(Features.all(), &(&1 in features))

    case Features.closed(present) do
      ^present -> present
      fewer -> kept(fewer)
    end
  end

  # The features a form names, as atoms of `Apiary.Features.all/0`, and the parts of
  # them, of `Apiary.Features.parts/0`; any other name is refused, as a feature the
  # granter does not have. A part is offered only while features are shown by who asks
  # (`shown/1`), so a form that names one otherwise is refused by `within/2`.
  defp names(features) when is_list(features) do
    all = Features.all() ++ Features.parts()
    known = Map.new(all, &{Atom.to_string(&1), &1})

    Enum.reduce_while(features, {:ok, []}, fn
      feature, {:ok, acc} when is_atom(feature) ->
        if feature in all,
          do: {:cont, {:ok, [feature | acc]}},
          else: {:halt, {:error, :above}}

      feature, {:ok, acc} when is_binary(feature) ->
        case Map.fetch(known, feature) do
          {:ok, feature} -> {:cont, {:ok, [feature | acc]}}
          :error -> {:halt, {:error, :above}}
        end

      _other, _acc ->
        {:halt, {:error, :above}}
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.uniq(list)}
      error -> error
    end
  end

  defp names(_features), do: {:error, :above}

  defp cast(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end
end
