defmodule ApiaryPro.Grants do
  @moduledoc """
  Writing what each link below the instance has (`ApiaryPro.Features`, Below the instance):
  the grants, each asked of `Apiary.Access` and each an audit entry.

  - `set_organisation/3` (`instance.grant_features`, an instance admin's, on the instance
    page): what an operator is granted, opt-in, or what any other organisation keeps,
    opt-out, of the instance's. Never the instance organisation, which has everything the
    instance has.

  A workspace has its organisation's features: no grant names a workspace.

  A grant above what the granter has is refused at write, `{:error, :above}`, and so is a
  feature without the features it needs, `{:error, :needs}`. When a link narrows later,
  everything below is clipped where it is read (`ApiaryPro.Features.of/2`), with no
  rewrite.

  The grants follow an organisation when it changes where it sits, in the transaction of
  that change (`written_out/2`): made an operator, it is granted what it had, and from then
  only a grant changes it; made an organisation again, it keeps what it had, opt-out; a new
  operator is granted what the instance has.

  **Race safety.** A write asks `Apiary.Access` first, then locks the organisation's row
  `FOR NO KEY UPDATE` (`ApiaryPro.Tenants.lock_organisations/2`). It asks again once the
  row is held, so a suspension that locked it first is seen. A write in flight holds it
  `FOR SHARE` and is waited for; a row that only refers to it, `FOR KEY SHARE`, is not. A
  change that holds it while it is written (`Apiary.Access.reload/2` with `lock: :share`,
  which reads the features after its locks) is written first, and one asked after waits
  and then sees the narrower features. A grant takes organisation rows only, and renders
  nothing: the organisation's policy holds above its workspaces whatever it is granted
  (`ApiaryPro.OrganisationPolicy`). A grant that changes something tells the people it
  reaches, whose open pages load their scope again.

  A write changes only the features a page shows (`shown/1`): a grant of a feature not
  shown, one the granter lacks or one not built, stays as stored, and an operator keeps
  `managed_organisations`, which it loses only by being made an organisation. A suspended
  organisation is granted nothing, `{:error, :suspended}`. The entry records the
  built features a grant can name, before and after.
  """

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Features, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.{Flags, Tenants, WorkspaceOperators}
  alias ApiaryPro.Grants.Grant

  @typedoc "A feature, or its name, as a form sends it."
  @type feature_name :: Features.feature() | String.t()

  ## Reading, for the pages

  @doc """
  offered/1 is the features a grant or a narrowing of `organisation` may name, in the
  order of `Apiary.Features.all/0`: the instance's. Never one only the instance switches
  (`ApiaryPro.Features.instance_switched/0`), which no grant names.
  """
  @spec offered(%Organisation{}) :: [Features.feature()]
  def offered(%Organisation{}), do: Features.enabled() -- ApiaryPro.Features.instance_switched()

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
  # run's Terminal under Runs, and a write changes them; only those a grant can name
  # (`ApiaryPro.Grants.Grant`). A part is shown unless a row of the organisation hides it,
  # whatever its kind, so its box is checked where none does (`parts_kept/1`). None while
  # the switch is off: a form that names a part then names a feature the granter lacks,
  # `{:error, :above}`.
  defp parts_shown(_organisation, shown) do
    if Flags.feature_visibility?() do
      for part <- Features.parts(),
          part in Ecto.Enum.values(Grant, :feature),
          Features.feature_of(part) in shown,
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
  the instance organisation): an operator is granted them, any other organisation keeps
  them and has the others taken away. An entry of `instance.grant_features`
  in the organisation's trail, with its features before and after; nothing changes and
  nothing is recorded when they are the same.

  `{:ok, features}`; `{:error, :above}` for a feature the instance does not have, or an operator's
  `managed_organisations`; `{:error, :needs}` for one without the features it needs;
  `{:error, :suspended}` for a suspended organisation; `{:error, :changed}` for one whose
  kind changed since the form was read; `{:error, :forbidden}` for the instance
  organisation, which has everything the instance has; `{:error, :not_found}` for one not
  there or marked for deletion; `{:error, :busy}` for a change that came at the same
  moment, to try again, and `Apiary.Access`'s answer otherwise.
  """
  @spec set_organisation(Scope.t(), Ecto.UUID.t(), [feature_name]) ::
          {:ok, [Features.feature()]}
          | {:error, :above | :needs | :busy | Access.reason() | term}
  def set_organisation(%Scope{} = scope, organisation_id, features) do
    with {:ok, id} <- cast(organisation_id),
         {:ok, features} <- names(features) do
      Repo.transact(fn ->
        # Asked first, then the organisation locked. What was asked of is read again under
        # the lock.
        with %Organisation{} = seen <- get_organisation(id) || {:error, :not_found},
             :ok <- Access.authorize(scope, :"instance.grant_features", seen),
             {:ok, held} <- Tenants.lock_organisations([id], :no_key_update),
             %Organisation{} = organisation <- held[id] || {:error, :not_found},
             :ok <- Access.check(scope, :"instance.grant_features", organisation),
             # A form of a kind it no longer has: an operator's features are not an
             # organisation's, nor the other way round.
             true <- Tenants.kind(organisation) == Tenants.kind(seen) || {:error, :changed},
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

  ## When an organisation changes where it sits

  @doc """
  written_out/2 writes the grants an organisation has when it changes where it sits, in
  the transaction of that change, which asked `Apiary.Access` and records it: `:operator`,
  made an operator, is granted what it has (`features:` what it had before, as an
  organisation) or, for a new one, what the instance has of the features a grant can name,
  and `managed_organisations` always, so a feature the instance gains reaches it once
  granted; `:organisation`, made an organisation again, keeps what it had and has the rest
  taken away. Only the features a grant can name are written (`ApiaryPro.Grants.Grant`).
  The organisation's rows are replaced, but those that hide a part. `{:ok, features}`:
  what its rows grant, for an operator; the instance's features but what its rows take
  away, for an organisation made one again; either without a feature whose needs are not
  among them (`Apiary.Features.closed/1`). Not what it is shown, which
  `ApiaryPro.Features.of/2` answers.
  """
  @spec written_out(%Organisation{}, :operator | :organisation, keyword) ::
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
      true
    )
  end

  def written_out(%Organisation{} = organisation, :organisation, opts) do
    had = Keyword.get(opts, :features, [])
    replace(organisation, Features.enabled() -- had, false)
  end

  ## Helpers

  # Once a change that wrote an entry is committed, the people it reaches are told, so their
  # open pages load their scope again, with its features
  # (`ApiaryWeb.UserAuth.reload_scope/1`): the organisation's, and those of the operators
  # of its workspaces, who are shown its features there.
  defp tell({:ok, {:unchanged, features}}, _organisation_id), do: {:ok, features}

  defp tell({:ok, {:changed, features}}, organisation_id) do
    ids = [organisation_id | WorkspaceOperators.operator_ids_of(organisation_id)]

    Repo.all(from m in Apiary.Organisations.Membership, where: m.organisation_id in ^ids)
    |> Apiary.Organisations.broadcast_membership_changes()

    {:ok, features}
  end

  defp tell(result, _organisation_id), do: result

  # The organisation's grant rows replaced: `granted` for each feature named that a grant
  # can name. One its schema has no value for, such as the core's `secrets`, has no
  # row to hold it and is not written.
  #
  # The rows that hide a part (`ApiaryPro.Features.hidden/1`) stay where it changes kind,
  # as it keeps what it had: its people are hidden the same parts.
  defp replace(%Organisation{id: id}, features, granted) do
    names = Ecto.Enum.values(Grant, :feature)
    features = Enum.filter(features, &(&1 in names))
    kept = Enum.filter(Features.parts(), &(&1 in names))

    Repo.delete_all(from g in Grant, where: g.organisation_id == ^id and g.feature not in ^kept)

    insert_rows(id, features, granted)
    {:ok, Features.closed(if(granted, do: features, else: Features.enabled() -- features))}
  end

  # The rows of one organisation for the features `shown`, which the form names or leaves
  # out: an operator is granted what it names, any other organisation has what it leaves
  # out taken away. The rows of the features not shown stay as they are
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
  # which only an entry written while features are shown by who asks names.
  defp listed({features, parts}) do
    recorded = Features.built() -- ApiaryPro.Features.instance_switched()

    for feature <- features,
        feature in recorded,
        name <- [feature | Enum.filter(parts, &(Features.feature_of(&1) == feature))],
        do: name
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

  defp opt_in?(%Organisation{} = organisation), do: Tenants.operator?(organisation)

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
