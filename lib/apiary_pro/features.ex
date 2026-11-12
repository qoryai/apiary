defmodule ApiaryPro.Features do
  @moduledoc """
  The edition's features (`c:Apiary.Edition.features/0`), what each organisation is
  shown of the instance's (`of/1`), and what a person is not shown in an organisation
  (`c:Apiary.Edition.hidden/1`, `hidden/1`).

  | Feature | Covers | Needs |
  |---|---|---|
  | `managed_organisations` | operators and their clients, and what an operator does for them | `observability` |
  | `organisation_policy` | the organisation's policy above its workspaces' security policy: its host rules, the mode floor and the switch (`ApiaryPro.OrganisationPolicy`) | `security` |
  | `organisation_variables` | the organisation's secrets, beside each workspace's secrets (`ApiaryPro.OrganisationSecrets`), and its variables, which every workspace inherits, above each workspace's variables: its names and values, and the names it locks (`ApiaryPro.OrganisationVariables`) | `security`, `secrets` |

  ## Below the instance

  Below the instance a feature is shown or hidden, never switched off: what the instance
  has works in full for every organisation's nodes and runs, and what an organisation is
  not shown is hidden from its people, its pages and actions not found
  (`Apiary.Features.visible?/2`). The chain is instance, operator, client, and each link
  can only narrow the one above it, from the instance's features and the grants
  (`ApiaryPro.Grants.Grant`, written by `ApiaryPro.Grants`), a grant `granted` where its
  feature is shown and not `granted` where it is hidden:

  - **The instance organisation** is shown every feature the instance has, whatever its
    kind.
  - **An operator** is shown what an instance admin granted it, of the instance's:
    **opt-in**, so a feature a grant can name, added to the instance later, is shown to
    it only once granted.
  - **A client** is shown what its operator granted it, of the operator's features: opt-in
    too. A client is never shown `managed_organisations`: it manages no one.
  - **An organisation with no operator** is shown what the instance has, but for what an
    instance admin hid: **opt-out**, so a feature the instance gains is shown to it.
  - **A workspace** is shown what its organisation is shown.

  The features no grant can name (`ApiaryPro.Grants.Grant`), the core's features but
  `observability` and `security`, such as `secrets`, are shown to an operator and a client
  wherever the instance has them, as to any organisation: only the instance switches them.

  A feature is shown only with the features it needs, and those with theirs
  (`Apiary.Features.closed/1`), so an organisation not shown `observability` is shown none
  of the others.
  """

  import Ecto.Query, warn: false

  alias Apiary.{Features, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.{Flags, Reach, Tenants}
  alias ApiaryPro.Grants.Grant
  alias ApiaryPro.Tenants.Tenant

  # The features only the instance switches: no grant names them
  # (`ApiaryPro.Grants.Grant`), and an operator and a client are shown each the instance
  # has, as any organisation is. Every feature is either here or a grant's
  # (`ApiaryPro.FeaturesTest`), so a feature the core adds fails the tests until it is
  # placed in one of the two.
  @instance_switched [:secrets, :path_rules, :factory, :registry, :workflow_model]

  # The parts of no feature (`Apiary.Features.parts/0`) only an operator hides, for one
  # client at a time: `:nodes`, the nodes, the node pools, their access keys and the
  # gateways (`client_parts/1`).
  @client_parts [:nodes]

  @doc """
  features/0 is the edition's features, after the core's, each with its needs and whether
  it is built.
  """
  @spec features() :: [{Features.feature(), keyword}]
  def features,
    do: [
      managed_organisations: [needs: [:observability], built: true],
      organisation_policy: [needs: [:security], built: true],
      organisation_variables: [needs: [:security, :secrets], built: true]
    ]

  @doc """
  of/2 is the features `organisation` is shown, of `enabled`, the instance's by default,
  as the database has them now (Below the instance, above), in the order of `enabled`:
  the instance's for the instance organisation, of either kind; what an operator or a
  client was granted, and the features only the instance switches (`instance_switched/0`,
  the core's features but `observability` and `security`, such as `secrets`), within the
  instance's and a client's operator's; the instance's but what was hidden for an
  organisation with no operator. The organisation's kind and operator are its tenant's,
  as it carries it (`ApiaryPro.Tenants`). One read, two for a client.
  """
  @spec of(%Organisation{}, [Features.feature()]) :: [Features.feature()]
  def of(%Organisation{} = organisation, enabled \\ Features.enabled()) do
    organisation = Tenants.put_tenant(organisation, Tenants.tenant(organisation))
    rows = grant_rows([organisation.id | List.wrap(Tenants.operator_id(organisation))])
    closure(organisation_features(organisation, rows, enabled))
  end

  # The features kept only with the features they need, until none is left without one:
  # `Apiary.Features.closed/1` takes one pass, so a feature whose needs lose one of
  # theirs in it is taken out by the next. Not shown Runs, an organisation is shown
  # neither the security policy nor what needs it.
  defp closure(features) do
    case Features.closed(features) do
      ^features -> features
      fewer -> closure(fewer)
    end
  end

  @doc """
  of_organisation/1 is `of/2` for the organisation `organisation_id`, as the database has
  it now; [] for one that is not there.
  """
  @spec of_organisation(Ecto.UUID.t()) :: [Features.feature()]
  def of_organisation(organisation_id) do
    case Repo.get(Organisation, organisation_id) do
      %Organisation{} = organisation -> of(organisation)
      nil -> []
    end
  end

  @doc """
  hidden/1 is what the scope's person is not shown in the scope's organisation
  (`c:Apiary.Edition.hidden/1`): the features the instance has that the organisation is
  not shown (`of/2`), the same for every workspace of it; nothing for a scope without an
  organisation. A plain read, under the locks the core's `Apiary.Access.reload/2` holds
  when it asks with `lock: :share`.
  """
  @spec hidden(Scope.t()) :: [Features.name()]
  def hidden(%Scope{organisation: %Organisation{} = organisation} = scope) do
    enabled = Features.enabled()
    (enabled -- shown_to(scope, organisation, enabled)) ++ parts_hidden_from(scope, organisation)
  end

  def hidden(_scope), do: []

  # What the person is shown in the organisation.
  #
  # By place, whoever asks: what the organisation is shown. A client is shown what it was
  # granted of its operator's, so its people do not see what is hidden from the client,
  # nor what is hidden from its operator.
  #
  # While `ApiaryPro.Flags.feature_visibility?/0` is on, by who asks as well:
  #
  # - a person who reaches a client through a level in its operator (`reach`
  #   `{:operator, membership}`, `ApiaryPro.Reach.operator_level/1`) sees in it what the
  #   operator is shown, whether or not they are a member of the client too;
  # - an instance admin who reaches an organisation through the instance (`reach`
  #   `:instance`, `ApiaryPro.Reach.instance_reach?/1`) sees every feature the instance
  #   has. Their role there is still reader (`ApiaryPro.Access`), so a feature hidden from
  #   the organisation is readable to them and changes nothing.
  #
  # Where the scope carries no reach of the edition's, the core's `load_scope/2` and
  # `load_home_scope/2`, which put the membership without `c:Apiary.Edition.reach/1`, the
  # answer is by place: a person who is a member of a client and holds a level in its
  # operator is then not shown what is hidden from the client either, more hidden and
  # never less, but for the nodes (`parts_hidden_from/2`). Those scopes serve lists and
  # the person's home and instance pages, which gate no feature;
  # `ApiaryPro.Reach.reload/2` puts the reach back for a client, so a check read again
  # under `Apiary.Access.reload/2` asks with it.
  #
  # The locks: under `Apiary.Access.reload/2` with `lock: :share` the core holds the
  # organisation's row and, for a client, its operator's `FOR SHARE`
  # (`ApiaryPro.Reach.places_to_lock/1`), and the edition the operator's people lock
  # (`ApiaryPro.Tenants.lock_rows/1`, `{:places, scope}`), before `hidden/1` is asked.
  # What is read here is covered by them: an organisation's tenant and its grant rows are
  # written only while its row is held `FOR NO KEY UPDATE` or `FOR UPDATE`
  # (`ApiaryPro.Grants`, `ApiaryPro.Transfers`, `ApiaryPro.Operators`), or, for an
  # organisation being created, before anyone reaches it; so a grant, a change of kind or
  # a parting waits for the read, or came first and is read. The reach this asks of was
  # read again under the operator's people lock (`ApiaryPro.Reach.reload/2`), and so is
  # the membership in the operator that `parts_hidden_from/2` reads for the nodes, which
  # that lock covers as it covers the reach. Nothing more is locked for it.
  #
  # An open page reads this again only when its person is told of a change of their
  # memberships (`Apiary.Organisations.broadcast_membership_changes/1`), so each change of
  # what is read here tells the people whose answer it changes: a grant, the people of the
  # organisation, of its clients and of its operator (`ApiaryPro.Grants`); a change of
  # kind, the organisation's people (`ApiaryPro.Operators.change_kind/3`); a new client,
  # the operator's; a drop, a leave and an accepted offer, the people of the client and of
  # the operator (`ApiaryPro.Transfers`); a suspension, the people it reaches
  # (`ApiaryPro.Suspensions`); a membership, the core. An instance admin who reaches an
  # organisation through the instance is told none of these: with the switch on they are
  # shown everything, and with it off they are as before.
  #
  # The parts of a feature (`Apiary.Features.parts/0`), the run's Terminal first, are
  # hidden only while the switch is on (`parts_hidden_from/2`), and a person is shown a
  # part wherever they are shown its feature, but where a row hides it. The nodes, a part
  # of no feature, are hidden only from a client's people, where its row hides them
  # (`client_parts/1`).
  defp shown_to(scope, organisation, enabled) do
    if Flags.feature_visibility?() do
      cond do
        Reach.instance_reach?(scope) ->
          enabled

        Reach.operator_level(scope) != nil ->
          of(%Organisation{id: Tenants.operator_id(organisation)}, enabled)

        true ->
          of(organisation, enabled)
      end
    else
      of(organisation, enabled)
    end
  end

  # The parts hidden from the scope's person, while features are shown by who asks
  # (`ApiaryPro.Flags.feature_visibility?/0`); none while it is off, whatever rows there
  # are, so every part is shown wherever its feature is. A part is shown unless a row
  # hides it (`granted` false), whatever the kind of the organisation the row is of, and
  # the row of an operator hides it from its clients too: from the people of each client,
  # as every feature it is not shown is, down the chain. Who asks, as `shown_to/3`: an
  # instance admin who reaches the organisation through the instance is hidden no part,
  # and a person who reaches a client through a level in its operator is hidden what the
  # operator is, the operator's rows, not the client's. The core hides a part of a feature
  # hidden from the person as well (`Apiary.Features.visible?/2`), so only a row hides one
  # here. Read under the locks `hidden/1` says, as the features are: a part's row is
  # written as a feature's is (`ApiaryPro.Grants`).
  #
  # The nodes, `:nodes`, are hidden only by the client's row, and only while both
  # switches are on (`client_parts/1`): never from an organisation with no operator, the
  # instance organisation or an operator, and never from a person with a level in the
  # client's operator, who sees what the operator is shown. That holds by place too,
  # where the scope carries no reach (`shown_to/3`): a person with an unsuspended
  # membership in the operator (`ApiaryPro.Reach.operator_membership/3`) is not hidden
  # them there, unlike the run's Terminal and the features, which stay more hidden by
  # place. The membership is read only where the client's row hides the nodes.
  defp parts_hidden_from(scope, organisation) do
    if Flags.feature_visibility?() do
      cond do
        Reach.instance_reach?(scope) ->
          []

        Reach.operator_level(scope) != nil ->
          hidden_parts([Tenants.operator_id(organisation)]) -- @client_parts

        true ->
          hidden = hidden_in(organisation)

          if Enum.any?(@client_parts, &(&1 in hidden)) and operator_person?(scope, organisation),
            do: hidden -- @client_parts,
            else: hidden
      end
    else
      []
    end
  end

  # Whether the scope's person holds an unsuspended membership in the client's operator.
  defp operator_person?(%Scope{user: %User{id: user_id}}, organisation),
    do: Reach.operator_membership(organisation, user_id) != nil

  defp operator_person?(_scope, _organisation), do: false

  # The parts hidden in `organisation` by place, in the order of
  # `Apiary.Features.parts/0`: a part of a feature where a row of it or of a client's
  # operator hides it, and a part only an operator hides (`client_parts/1`) where the
  # client's row does. One read.
  defp hidden_in(organisation) do
    ids = [organisation.id | List.wrap(Tenants.operator_id(organisation))]
    client_parts = client_parts(organisation)

    hidden =
      for {id, part} <-
            Repo.all(
              from g in Grant,
                where: g.organisation_id in ^ids and not g.granted,
                select: {g.organisation_id, g.feature}
            ),
          part not in @client_parts or (id == organisation.id and part in client_parts),
          do: part

    Enum.filter(Features.parts(), &(&1 in hidden))
  end

  # client_parts/1 is the parts of no feature an operator may hide from the people of
  # `organisation`, a client (`@client_parts`): the nodes, `:nodes`, while the operator
  # owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`) and features are shown
  # by who asks (`ApiaryPro.Flags.feature_visibility?/0`). None for any other
  # organisation, an operator, one with no operator and the instance organisation among
  # them, and none with either switch off. Unlike a part of a feature, the nodes are shown
  # unless the client's row hides them, whatever its features. For `ApiaryPro.Grants`,
  # which offers them on the client's Features page.
  @doc false
  @spec client_parts(%Organisation{}) :: [Features.part()]
  def client_parts(%Organisation{} = organisation) do
    if Flags.operator_infrastructure?() and Flags.feature_visibility?() and
         Tenants.client?(organisation) and not Tenants.instance_organisation?(organisation),
       do: @client_parts,
       else: []
  end

  # hidden_parts/1 is the parts the rows of the organisations named hide, in the order of
  # `Apiary.Features.parts/0`: one read. For `ApiaryPro.Grants`, which offers and keeps
  # them on the Features pages, and `hidden/1`.
  @doc false
  @spec hidden_parts([Ecto.UUID.t()]) :: [Features.part()]
  def hidden_parts(organisation_ids) do
    hidden =
      Repo.all(
        from g in Grant,
          where: g.organisation_id in ^organisation_ids and not g.granted,
          select: g.feature
      )

    Enum.filter(Features.parts(), &(&1 in hidden))
  end

  # parts_of/2 is the parts `organisation` is shown, of the features it is shown,
  # `features` (`of/2`): those of its features, and for a client the nodes
  # (`client_parts/1`), but the parts hidden there by place (`hidden_in/1`). One read. For
  # the entries of `ApiaryPro.Grants`, while features are shown by who asks.
  @doc false
  @spec parts_of(%Organisation{}, [Features.feature()]) :: [Features.part()]
  def parts_of(%Organisation{} = organisation, features) do
    hidden = hidden_in(organisation)
    client_parts = client_parts(organisation)

    for part <- Features.parts(),
        Features.feature_of(part) in features or part in client_parts,
        part not in hidden,
        do: part
  end

  @doc """
  of_all/1 is `of/2` for each of `organisations`, as a map of their ids:
  two reads however many there are, for a page that lists them.
  """
  @spec of_all([%Organisation{}]) :: %{Ecto.UUID.t() => [Features.feature()]}
  def of_all([]), do: %{}

  def of_all(organisations) do
    enabled = Features.enabled()
    organisations = Tenants.ensure(organisations)

    operator_ids =
      for organisation <- organisations,
          id = Tenants.operator_id(organisation),
          uniq: true,
          do: id

    rows = grant_rows(Enum.map(organisations, & &1.id) ++ operator_ids)

    instance_organisations =
      Repo.all(
        from t in Tenant,
          where: t.organisation_id in ^operator_ids and t.instance_organisation,
          select: t.organisation_id
      )
      |> MapSet.new()

    Map.new(organisations, fn organisation ->
      if Tenants.client?(organisation) and not Tenants.instance_organisation?(organisation) do
        {organisation.id,
         closure(client_features(organisation, rows, instance_organisations, enabled))}
      else
        {organisation.id, closure(organisation_features(organisation, rows, enabled))}
      end
    end)
  end

  # The grant rows of the organisations named, each one's and its operator's, one read:
  # `{organisation_id, feature, granted}`.
  defp grant_rows(organisation_ids) do
    Repo.all(
      from g in Grant,
        where: g.organisation_id in ^organisation_ids,
        select: {g.organisation_id, g.feature, g.granted}
    )
  end

  defp organisation_features(%Organisation{id: id} = organisation, rows, enabled) do
    tenant = Tenants.tenant(organisation)

    cond do
      tenant.instance_organisation ->
        enabled

      tenant.kind == :operator ->
        granted(rows, id, enabled)

      is_binary(tenant.operator_id) ->
        instance_organisations =
          Repo.all(
            from t in Tenant,
              where: t.organisation_id == ^tenant.operator_id and t.instance_organisation,
              select: t.organisation_id
          )

        client_features(organisation, rows, MapSet.new(instance_organisations), enabled)

      true ->
        enabled -- for({^id, feature, false} <- rows, do: feature)
    end
  end

  # A client: what it was granted, of its operator's, the instance's for the instance
  # organisation as an operator, but `managed_organisations`.
  defp client_features(
         %Organisation{id: id} = organisation,
         rows,
         instance_organisations,
         enabled
       ) do
    operator_id = Tenants.operator_id(organisation)

    operator =
      if MapSet.member?(instance_organisations, operator_id),
        do: enabled,
        else: granted(rows, operator_id, enabled)

    granted(rows, id, operator -- [:managed_organisations])
  end

  # Opt-in: what `id` was granted, of `within`, and every feature of `within` only the
  # instance switches (`instance_switched/0`), which no grant names: an operator and a
  # client are shown it as any organisation is.
  defp granted(rows, id, within) do
    granted = for {^id, feature, true} <- rows, do: feature
    Enum.filter(within, &(&1 in granted or &1 in @instance_switched))
  end

  @doc """
  instance_switched/0 is the features only the instance switches (`QORY_FEATURES`), which
  no grant names (`ApiaryPro.Grants.Grant`): the core's features but `observability` and
  `security`, such as `secrets`. Every organisation the instance has one for is shown it,
  an operator and a client too, with the features it needs (`Apiary.Features.closed/1`).
  """
  @spec instance_switched() :: [Features.feature()]
  def instance_switched, do: @instance_switched
end
