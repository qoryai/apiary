defmodule ApiaryPro.Features do
  @moduledoc """
  The edition's features (`c:Apiary.Edition.features/0`), what each organisation is
  shown of the instance's (`of/1`), and what a person is not shown in an organisation
  (`c:Apiary.Edition.hidden/1`, `hidden/1`).

  | Feature | Covers | Needs |
  |---|---|---|
  | `managed_organisations` | operators, and the workspaces they operate | `observability` |
  | `organisation_policy` | the organisation's policy above its workspaces' security policy: its host rules, the mode floor and the switch (`ApiaryPro.OrganisationPolicy`) | `security` |
  | `organisation_variables` | the organisation's secrets, beside each workspace's secrets (`ApiaryPro.OrganisationSecrets`), and its variables, which every workspace inherits, above each workspace's variables: its names and values, and the names it locks (`ApiaryPro.OrganisationVariables`) | `security`, `secrets` |

  ## Below the instance

  Below the instance a feature is shown or hidden, never switched off: what the instance
  has works in full for every organisation's nodes and runs, and what an organisation is
  not shown is hidden from its people, its pages and actions not found
  (`Apiary.Features.visible?/2`). An organisation can only narrow what the instance has,
  from the instance's features and the grants (`ApiaryPro.Grants.Grant`, written by
  `ApiaryPro.Grants`), a grant `granted` where its feature is shown and not `granted`
  where it is hidden:

  - **The instance organisation** is shown every feature the instance has, whatever its
    kind.
  - **An operator** is shown what an instance admin granted it, of the instance's:
    **opt-in**, so a feature a grant can name, added to the instance later, is shown to
    it only once granted.
  - **Any other organisation** is shown what the instance has, but for what an instance
    admin hid: **opt-out**, so a feature the instance gains is shown to it.
  - **A workspace** is shown what its organisation is shown, to everyone who works in it,
    the people of its operator included.

  The features no grant can name (`ApiaryPro.Grants.Grant`), the core's features but
  `observability` and `security`, such as `secrets`, are shown to an operator wherever the
  instance has them, as to any organisation: only the instance switches them.

  A feature is shown only with the features it needs, and those with theirs
  (`Apiary.Features.closed/1`), so an organisation not shown `observability` is shown none
  of the others.
  """

  import Ecto.Query, warn: false

  alias Apiary.{Features, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.{Flags, Reach, Tenants}
  alias ApiaryPro.Grants.Grant

  # The features only the instance switches: no grant names them
  # (`ApiaryPro.Grants.Grant`), and an operator is shown each the instance has, as any
  # organisation is. Every feature is either here or a grant's
  # (`ApiaryPro.FeaturesTest`), so a feature the core adds fails the tests until it is
  # placed in one of the two.
  @instance_switched [
    :secrets,
    :path_rules,
    :factory,
    :registry,
    :workflow_model,
    :feature_visibility
  ]

  # The edition's switches of the whole instance, opt-in features that `ApiaryPro.Flags`
  # reads (`Apiary.Features.on?/1`): an instance admin turns them on and off. No
  # organisation is shown them (`of/2`), and one is hidden them only with a feature they
  # need (`hidden/1`).
  @switches [:feature_visibility]

  @doc """
  features/0 is the edition's features, after the core's, each with its needs and whether
  it is built.
  """
  @spec features() :: [{Features.feature(), keyword}]
  def features,
    do: [
      managed_organisations: [needs: [:observability], built: true],
      organisation_policy: [needs: [:security], built: true],
      organisation_variables: [needs: [:security, :secrets], built: true],
      # A switch of the whole instance, opt-in and left out of the documentation
      # (`ApiaryPro.Flags`): `feature_visibility?/0` reads it. No grant names it.
      feature_visibility: [needs: [:observability], built: true, default: false, docs: false]
    ]

  @doc """
  of/2 is the features `organisation` is shown, of `enabled`, the instance's by default,
  as the database has them now (Below the instance, above), in the order of `enabled`:
  the instance's for the instance organisation, of either kind; what an operator was
  granted, and the features only the instance switches (`instance_switched/0`, the core's
  features but `observability` and `security`, such as `secrets`), within the instance's;
  the instance's but what was hidden for any other organisation. The organisation's kind
  is its tenant's, as it carries it (`ApiaryPro.Tenants`). One read.
  """
  @spec of(%Organisation{}, [Features.feature()]) :: [Features.feature()]
  def of(%Organisation{} = organisation, enabled \\ Features.enabled()) do
    organisation = Tenants.put_tenant(organisation, Tenants.tenant(organisation))
    rows = grant_rows([organisation.id])
    closure(organisation_features(organisation, rows, enabled))
  end

  # The features kept only with the features they need, until none is left without one:
  # `Apiary.Features.closed/1` takes one pass, so a feature whose needs lose one of
  # theirs in it is taken out by the next. Not shown Runs, an organisation is shown
  # neither the security policy nor what needs it. The switches of the whole instance
  # (`@switches`) are left out: no organisation is shown or hidden them.
  defp closure(features) do
    case Features.closed(features) do
      ^features -> features -- @switches
      fewer -> closure(fewer)
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
    taken = (enabled -- @switches) -- shown_to(scope, organisation, enabled)

    # A switch of the whole instance is hidden only with a feature it needs, as
    # `Apiary.Features.hidden_of/1` adds it.
    switches =
      for switch <- @switches,
          Enum.any?(Features.needs(switch), &(&1 in taken)),
          do: switch

    Enum.filter(enabled, &(&1 in taken or &1 in switches)) ++
      parts_hidden_from(scope, organisation)
  end

  def hidden(_scope), do: []

  # What the person is shown in the organisation.
  #
  # By place, whoever asks: what the organisation is shown. A person of an operator who
  # works in a workspace of the organisation that the operator operates is shown the
  # same, so they never see more there than the organisation is granted.
  #
  # While `ApiaryPro.Flags.feature_visibility?/0` is on, an instance admin who reaches an
  # organisation through the instance (`reach` `:instance`,
  # `ApiaryPro.Reach.instance_reach?/1`) sees every feature the instance has. Their role
  # there is still reader (`ApiaryPro.Access`), so a feature hidden from the organisation
  # is readable to them and changes nothing.
  #
  # The locks: under `Apiary.Access.reload/2` with `lock: :share` the core holds the
  # organisation's row and, for a client, its operator's `FOR SHARE`
  # (`ApiaryPro.Reach.places_to_lock/1`), and the edition the operator's people lock
  # (`ApiaryPro.Tenants.lock_rows/1`, `{:places, scope}`), before `hidden/1` is asked.
  # What is read here is covered by them: an organisation's tenant and its grant rows are
  # written only while its row is held `FOR NO KEY UPDATE` or `FOR UPDATE`
  # (`ApiaryPro.Grants`, `ApiaryPro.Operators`), or, for an organisation being created,
  # before anyone reaches it; so a grant or a change of kind waits for the read, or came
  # first and is read.
  #
  # An open page reads this again only when its person is told of a change of their
  # memberships (`Apiary.Organisations.broadcast_membership_changes/1`), so each change of
  # what is read here tells the people whose answer it changes: a grant, the people of the
  # organisation and of the operators of its workspaces (`ApiaryPro.Grants`); a change of
  # kind, the organisation's people (`ApiaryPro.Operators.change_kind/3`); an accepted
  # offer, the organisation's people (`ApiaryPro.Transfers`); a membership, the core. An
  # instance admin who reaches an organisation through the instance is told none of these:
  # with the switch on they are shown everything, and with it off they are as before.
  #
  # The parts of a feature (`Apiary.Features.parts/0`), the run's Terminal first, are
  # hidden only while the switch is on (`parts_hidden_from/2`), and a person is shown a
  # part wherever they are shown its feature, but where a row hides it.
  defp shown_to(scope, organisation, enabled) do
    if Flags.feature_visibility?() and Reach.instance_reach?(scope),
      do: enabled,
      else: of(organisation, enabled)
  end

  # The parts hidden from the scope's person, while features are shown by who asks
  # (`ApiaryPro.Flags.feature_visibility?/0`); none while it is off, whatever rows there
  # are, so every part is shown wherever its feature is. A part is shown unless a row of
  # the organisation hides it (`granted` false), whatever its kind. Who asks, as
  # `shown_to/3`: an instance admin who reaches the organisation through the instance is
  # hidden no part; anyone else, a person of the operator of one of its workspaces
  # included, is hidden the parts hidden there by place. The core hides a part of a
  # feature hidden from the person as well (`Apiary.Features.visible?/2`), so only a row
  # hides one here. Read under the locks `hidden/1` says, as the features are: a part's
  # row is written as a feature's is (`ApiaryPro.Grants`).
  defp parts_hidden_from(scope, organisation) do
    if Flags.feature_visibility?() and not Reach.instance_reach?(scope),
      do: hidden_in(organisation),
      else: []
  end

  # The parts of a feature hidden in `organisation` by place, where a row of it hides
  # them, in the order of `Apiary.Features.parts/0`. One read.
  defp hidden_in(organisation) do
    for part <- hidden_parts([organisation.id]), Features.feature_of(part) != nil, do: part
  end

  # hidden_parts/1 is the parts the rows of the organisations named hide, in the order of
  # `Apiary.Features.parts/0`: one read. For `ApiaryPro.Grants`, which keeps them on the
  # Features page, and `hidden/1`.
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
  # `features` (`of/2`), but the parts hidden there by place (`hidden_in/1`). One read.
  # For the entries of `ApiaryPro.Grants`, while features are shown by who asks.
  @doc false
  @spec parts_of(%Organisation{}, [Features.feature()]) :: [Features.part()]
  def parts_of(%Organisation{} = organisation, features) do
    hidden = hidden_in(organisation)

    for part <- Features.parts(),
        Features.feature_of(part) in features,
        part not in hidden,
        do: part
  end

  @doc """
  of_all/1 is `of/2` for each of `organisations`, as a map of their ids: one read of the
  grants however many there are, for a page that lists them.
  """
  @spec of_all([%Organisation{}]) :: %{Ecto.UUID.t() => [Features.feature()]}
  def of_all([]), do: %{}

  def of_all(organisations) do
    enabled = Features.enabled()
    organisations = Tenants.ensure(organisations)
    rows = grant_rows(Enum.map(organisations, & &1.id))

    Map.new(organisations, fn organisation ->
      {organisation.id, closure(organisation_features(organisation, rows, enabled))}
    end)
  end

  # The grant rows of the organisations named, one read: `{organisation_id, feature,
  # granted}`.
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
      tenant.instance_organisation -> enabled
      tenant.kind == :operator -> granted(rows, id, enabled)
      true -> enabled -- for({^id, feature, false} <- rows, do: feature)
    end
  end

  # Opt-in: what `id` was granted, of `within`, and every feature of `within` only the
  # instance switches (`instance_switched/0`), which no grant names: an operator is shown
  # it as any organisation is.
  defp granted(rows, id, within) do
    granted = for {^id, feature, true} <- rows, do: feature
    Enum.filter(within, &(&1 in granted or &1 in @instance_switched))
  end

  @doc """
  instance_switched/0 is the features only the instance switches (`QORY_FEATURES`), which
  no grant names (`ApiaryPro.Grants.Grant`): the core's features but `observability` and
  `security`, such as `secrets`. Every organisation the instance has one for is shown it,
  an operator too, with the features it needs (`Apiary.Features.closed/1`).
  The edition's opt-in switches of the whole instance are among them, and no organisation
  is shown or hidden those.
  """
  @spec instance_switched() :: [Features.feature()]
  def instance_switched, do: @instance_switched
end
