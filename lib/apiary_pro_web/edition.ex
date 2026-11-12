defmodule ApiaryProWeb.Edition do
  @moduledoc """
  The edition's web side (`ApiaryWeb.Edition`): what it adds to the core's pages.

  - The organisation's sidebar: **Policy**, the organisation's policy, in the first group,
    the one without a heading, after the core's entries there, where the feature is on
    (`ApiaryProWeb.PolicyLive.Organisation`), "Organisation policy" in the palette;
    **Clients**, an operator's clients, with their number beside it, and its policy
    requests, under Operator. The instance organisation is an
    organisation like any other to those who manage nobody: of the kind `organisation` it
    has no Clients entry, as any organisation has none; made an operator, its Clients
    entry is there once it has clients, and until then its owners reach its clients from
    Instance settings' Organisations.
  - The Instance level's sections after the core's General and before its Mail and
    Configuration (`instance_sections/1`): **Organisations** and **Accounts**, for the
    instance admins (`ApiaryProWeb.InstanceLive.Components`). The Qory Apiary menu's
    Instance settings leads to General, and the sections lead on to them.
  - The organisation menu's **New organisation**, where the instance opens a kind of
    organisation to the person (`ApiaryPro.Organisations.new_organisation_kinds/1`), and
    its heading of the clients a person reaches through an operator; **New workspace** in
    the workspace menu and in New on an organisation's pages, for an owner; and
    **Network access rule** in New on an organisation's pages, for an owner, where the
    organisation's policy is on: its New rule page.
  - The organisation settings' **Secrets and variables** section, with its Secrets and
    Variables tabs, where the feature `organisation_variables` is on, and, where it is off, a
    page of the keys of the model providers alone, with no tabs, for whoever changes them
    under `provider.write` where `factory` and `secrets` are shown
    (`ApiaryProWeb.SettingsLive.Secrets`, `ApiaryProWeb.SettingsLive.Variables`), and its
    **Ownership** section
    (`ApiaryProWeb.SettingsLive.Ownership`),
    **New workspace** on its Workspaces and on its overview, for an owner, which leads to the
    core's type cards, `/:org/workspaces/new`; the operator of a client on its People page,
    and each member's workspaces there, with the way to change them; a client's pending
    policy requests on its policy page (`ApiaryProWeb.Slots`), and its **Policy
    requests** in its organisation's first group, after Policy, where `security` is on
    (`ApiaryProWeb.PolicyRequestLive.Index`).
  - The `:notices` slot: that a person of a client's operator reads it and changes
    nothing, and the offer of an organisation's ownership to the admin it names
    (`ApiaryProWeb.Notices`).
  - The audit log's words for the edition's actions (`ApiaryProWeb.ActivityDescriber`).
  - The edition's sentences, in its catalogues (`ApiaryProWeb.Gettext`).
  - Where the level above a workspace's policy is read and changed
    (`above_policy_link/1`): the organisation's policy page, for the workspace's policy
    pages and Network access, where the organisation has a policy, and its New rule page
    for an owner, where a host only the organisation can allow is led.
  - The switcher's places: the heading of the clients a person reaches through an
    operator; and what the pages say to a person who reads an organisation as an
    instance admin or as a person of its operator (`ApiaryProWeb.Readers`).
  - The names no slug may be beyond the core's (`ApiaryWeb.ReservedSlugs`): the edition's pages
    of an organisation, its former top-level paths, and other reserved top-level names.
  """

  use ApiaryWeb.Edition
  use ApiaryProWeb, :verified_routes
  use Gettext, backend: ApiaryProWeb.Gettext

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias ApiaryPro.{ClientReach, Transfers}
  alias ApiaryProWeb.SettingsLive.{Ownership, SecretsAndVariables}
  alias ApiaryWeb.Nav.Entry

  @impl true
  def nav_entries(_scope) do
    [
      # The organisation's policy, in the first group, after the core's entries there
      # (Overview and Audit log).
      %Entry{
        section: :home,
        key: :organisation_policy,
        label: gettext("Policy"),
        long_label: gettext("Organisation policy"),
        icon: "hero-shield-check",
        path: fn organisation, _workspace -> ~p"/#{organisation}/policy" end,
        place: :organisation,
        action: :"organisation_policy.read"
      },
      %Entry{
        section: :operator,
        key: :clients,
        label: gettext("Clients"),
        icon: "hero-building-storefront",
        path: fn organisation, _workspace -> ~p"/#{organisation}/clients" end,
        place: :organisation,
        action: :"client.read",
        count: :clients,
        filter: &clients_shown?/2
      },
      %Entry{
        section: :operator,
        key: :client_requests,
        label: gettext("Policy requests"),
        icon: "hero-paper-airplane",
        path: fn organisation, _workspace -> ~p"/#{organisation}/clients/requests" end,
        place: :organisation,
        action: :"client.read",
        filter: &requests_shown?/2
      },
      # A client's policy requests from its operator, in its first group, after Policy.
      %Entry{
        section: :home,
        key: :policy_requests,
        label: gettext("Policy requests"),
        icon: "hero-inbox-arrow-down",
        path: fn organisation, _workspace -> ~p"/#{organisation}/policy-requests" end,
        place: :organisation,
        action: :"security_policy.read",
        filter: &inbox_shown?/2
      }
    ]
  end

  @impl true
  def nav_sections, do: [operator: gettext("Operator")]

  # Instance settings' Organisations and Accounts, for the instance admins: the second column
  # of the Instance level, before the core's Configuration.
  @impl true
  def instance_sections(scope), do: ApiaryProWeb.InstanceLive.Components.sections(scope)

  # Sign-up, on Instance settings › Configuration, after the core's Invitations.
  @impl true
  def configuration_parts(_scope), do: [ApiaryProWeb.InstanceLive.SignUpPart]

  # The instance organisation's Clients, once it is an operator, is there once it has
  # clients: an empty group means nothing in the sidebar, and its owners reach its clients
  # from Instance settings › Organisations. Any other organisation's is there wherever
  # `client.read` is allowed, which it is in an operator alone.
  defp clients_shown?(%{organisation: organisation}, counts) do
    if ApiaryPro.Tenants.instance_organisation?(organisation),
      do: clients_count(counts) > 0,
      else: true
  end

  defp clients_shown?(_scope, _counts), do: true

  # An operator's policy requests are `security`'s: with it off the page is not found, and
  # nothing leads to it. Where Clients is not shown, neither are they. While the operator
  # owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`) they are not there.
  defp requests_shown?(scope, counts),
    do:
      not ApiaryPro.Flags.operator_infrastructure?() and
        Apiary.Features.visible?(scope, :security) and clients_shown?(scope, counts)

  # A client's policy requests are `security`'s too, and there while it is a client: an
  # organisation that left its operator reaches its old requests at their address alone.
  # While the operator owns its clients they are not there.
  defp inbox_shown?(%{organisation: organisation} = scope, _counts),
    do:
      not ApiaryPro.Flags.operator_infrastructure?() and
        ApiaryPro.Tenants.client?(organisation) and Apiary.Features.visible?(scope, :security)

  defp inbox_shown?(_scope, _counts), do: false

  defp clients_count(%{clients: n}) when is_integer(n), do: n
  defp clients_count(_counts), do: 0

  # How many clients an operator has, beside Clients, for a reader who may list them; and
  # whether the instance's admins offer the reader the organisation's ownership, which the
  # notices say on every page (`ApiaryProWeb.Notices`). Such an offer is made while no
  # owner may act, so the offer is read only then.
  @impl true
  def nav_counts(scope) do
    clients =
      if Access.can?(scope, :"client.read", scope.organisation),
        do: %{clients: ApiaryPro.Operators.count_clients(scope)},
        else: %{}

    if ownership_offered?(scope),
      do: Map.put(clients, :ownership_offer, true),
      else: clients
  end

  defp ownership_offered?(%{organisation: organisation} = scope) do
    ApiaryPro.Reach.owner_suspended?(organisation) and
      Ownership.offered_to_reader?(scope, Transfers.pending(scope))
  end

  # New workspace, on an organisation's pages outside its workspaces, for an owner
  # (`workspace.create`), once the organisation has a workspace: the core's type cards,
  # `/:org/workspaces/new` (`ApiaryWeb.WorkspaceSetupLive`). An organisation with none
  # shows the cards on its overview instead, so New offers no workspace;
  # and with `organisation_policy`, a network access rule of the organisation's policy,
  # for an owner (`organisation_policy.edit`), on its New rule page
  # (`ApiaryProWeb.PolicyLive.Organisation`). The core shows only what the reader may do,
  # and the feature is that action's, which `Apiary.Access.can?/3` checks.
  @impl true
  def new_entries(%Scope{organisation: %{} = organisation}, :organisation) do
    new_workspace_entries(organisation) ++ organisation_rule_entries(organisation)
  end

  def new_entries(_scope, _place), do: []

  defp new_workspace_entries(organisation) do
    if Apiary.Organisations.has_workspace?(organisation) do
      [
        %Entry{
          key: :workspace,
          label: gettext("New workspace"),
          icon: "hero-squares-2x2",
          path: ~p"/#{organisation}/workspaces/new",
          place: :organisation,
          action: :"workspace.create"
        }
      ]
    else
      []
    end
  end

  defp organisation_rule_entries(organisation) do
    [
      %Entry{
        key: :organisation_rule,
        label: gettext("Network access rule"),
        icon: "hero-shield-check",
        path: ~p"/#{organisation}/policy/rules/new",
        place: :organisation,
        action: :"organisation_policy.edit"
      }
    ]
  end

  # New workspace at the foot of the breadcrumb's workspace menu, for whoever may add one
  # to the organisation (`workspace.create`), as New offers it on an organisation's pages.
  # The core shows the menu's entries as they come, so the action is asked here.
  @impl true
  def workspace_switcher_entries(%Scope{organisation: %{} = organisation} = scope) do
    if Access.can?(scope, :"workspace.create", organisation) do
      [
        %Entry{
          key: :new,
          label: gettext("New workspace"),
          icon: "hero-squares-2x2",
          path: ~p"/#{organisation}/workspaces/new",
          place: :organisation,
          action: :"workspace.create"
        }
      ]
    else
      []
    end
  end

  def workspace_switcher_entries(_scope), do: []

  @impl true
  def switcher_entries(scope) do
    if ApiaryPro.Organisations.new_organisation_kinds(scope) != [] do
      [
        %Entry{
          key: :new,
          label: gettext("New organisation"),
          icon: "hero-plus-micro",
          path: ~p"/users/organisations/new"
        }
      ]
    else
      []
    end
  end

  # The switcher lists the clients a person reaches through an operator under the
  # operator's name, after the organisations the person is a member of.
  @impl true
  def place_group(%ClientReach{operator_membership: %{organisation: %{name: name}}}),
    do: gettext("Clients of %{operator}", operator: name)

  def place_group(_place), do: nil

  # The core no longer asks for a place's scope: a workspace a menu links is opened
  # through `ApiaryWeb.SwitchController`, which reads the destination's scope when it is
  # followed.
  @impl true
  def place_scope(_place, _workspace), do: nil

  @impl true
  def reader_sentence(where, scope), do: ApiaryProWeb.Readers.sentence(where, scope)

  # The organisation's policy page, for a reader who may read it, where the organisation
  # has a policy: the workspace's policy pages and Network access lead there, and an owner
  # changes it there; for an owner, its New rule page, where a host only the organisation
  # can allow is led with the host filled in. Nil for anyone else, so that way is left out.
  @impl true
  def above_policy_link(%Scope{organisation: %{} = organisation} = scope) do
    if Access.can?(scope, :"organisation_policy.read", organisation) and
         ApiaryPro.OrganisationPolicy.above_workspace(%Apiary.Organisations.Workspace{
           organisation_id: organisation.id
         }) do
      can_change = Access.can?(scope, :"organisation_policy.edit", organisation)

      %{
        path: ~p"/#{organisation}/policy",
        can_change: can_change,
        new_rule_path: if(can_change, do: ~p"/#{organisation}/policy/rules/new")
      }
    end
  end

  def above_policy_link(_scope), do: nil

  # An operator is deleted once it has no clients (`ApiaryPro.Deletion.refusal/2`): its
  # owners delete each client that has no owner and drop each that has one, on Clients;
  # a deleted client is still its client until it is purged.
  @impl true
  def refusal_sentence(:has_clients),
    do:
      gettext(
        "An operator with clients cannot be deleted. On Clients, delete each client that has no owner and drop each one that has; a deleted client counts until it is purged."
      )

  def refusal_sentence(_reason), do: nil

  # While the operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`),
  # nobody in a client is made an owner (`ApiaryPro.Edition`'s `level_refusal/4`).
  @impl true
  def level_refusal_sentence(:operator_owns, scope) do
    with %{name: operator} <- owning_operator(scope),
         do:
           gettext(
             "Nobody in %{organisation} is made an owner: %{operator}, its operator, owns it.",
             organisation: scope.organisation.name,
             operator: operator
           )
  end

  def level_refusal_sentence(_reason, _scope), do: nil

  # The node and key actions a client's people are refused while the operator owns its
  # clients, a pool's instance limit among them.
  @managed_by_operator [
    :"node.create",
    :"node.edit",
    :"node.set_limit",
    :"node.delete",
    :"node.clear_instance",
    :"access_key.create_code",
    :"access_key.cancel_code",
    :"access_key.add",
    :"access_key.revoke"
  ]

  # The settings, beside the nodes, that the operator sets in a client.
  @set_by_operator [:"retention.edit", :"time_limit.edit"]

  # The settings the operator sets in a client only while the client's switch is on the
  # operator's model providers (`ApiaryPro.Tenants.model_chain/1`).
  @set_by_operator_chain [:"model_choice.write", :"provider.write", :"runtime.write"]

  @impl true
  # While the operator owns its clients, a client's rule locks are the operator's owners'
  # alone (`ApiaryPro.Access`): the refusal of a lock or an unlock, and of a change of a
  # locked rule, says so.
  def who_may_sentence(:"security_policy.lock", scope) do
    with %{name: operator} <- owning_operator(scope),
         do:
           gettext(
             "Only owners of %{operator}, its operator, lock, unlock or change a locked rule.",
             operator: operator
           )
  end

  # While the operator owns its clients, a client's nodes, node pools, gateways and their
  # access keys are the operator's owners' and admins' (`ApiaryPro.Access`): a refusal of
  # one of these in a client says so, in the words of the client's node pages.
  def who_may_sentence(about, %Scope{organisation: organisation})
      when about in @managed_by_operator,
      do: nodes_managed_by_sentence(organisation)

  # While the operator owns its clients, a client's retention and time limits are the
  # operator's, and its model choices, model providers and runtimes while its switch is on
  # the operator's (`ApiaryPro.Access`): a refusal of one of these in a client says who
  # sets them.
  def who_may_sentence(about, scope) when about in @set_by_operator,
    do: set_by_sentence(scope)

  def who_may_sentence(about, %Scope{organisation: organisation} = scope)
      when about in @set_by_operator_chain do
    if ApiaryPro.Tenants.model_chain(organisation) == :operator, do: set_by_sentence(scope)
  end

  # While the operator owns its clients, a client's adapters are connected by the operator's
  # owners and admins alone (`ApiaryPro.Access`): the workspace set-up's second step says
  # so to the client's people, who are refused Connect there.
  def who_may_sentence(:"adapter.connect", scope) do
    with %{name: operator} <- owning_operator(scope),
         do:
           gettext(
             "Owners and admins of %{operator}, its operator, connect work sources here. Ask one of them.",
             operator: operator
           )
  end

  # A client's admins create its workspaces as its owners do, and, while the operator owns
  # its clients, so do the operator's owners (`ApiaryPro.Access`): the dead end of New
  # workspace says so to a client's people who are refused. The core's words elsewhere.
  def who_may_sentence(:"workspace.create", %Scope{organisation: organisation} = scope) do
    if ApiaryPro.Tenants.client?(organisation) do
      case owning_operator(scope) do
        %{name: operator} ->
          gettext(
            "Only owners and admins of %{organisation}, and owners of %{operator}, create workspaces.",
            organisation: organisation.name,
            operator: operator
          )

        nil ->
          gettext("Only owners and admins of %{organisation} create workspaces.",
            organisation: organisation.name
          )
      end
    end
  end

  def who_may_sentence(_about, _scope), do: nil

  # While the operator owns its clients, an operator's organisation-level gateways serve
  # its clients' workspaces too (`ApiaryPro.Gateways`): the pages of an operator with
  # clients say so, with their number, and a client's Gateways page says that its nodes
  # can use the operator's gateways too, which the operator's owners and admins manage;
  # the core's sentences otherwise. The empty Gateways page's body is the core's but in a
  # client, an operator's with clients included.
  @impl true
  def gateway_reach_sentence(kind, organisation) when kind in [:intro, :empty] do
    case operator_owning(organisation) do
      %{name: operator} -> client_reach_sentence(kind, organisation.name, operator)
      nil -> served_reach_sentence(kind, organisation)
    end
  end

  def gateway_reach_sentence(kind, organisation), do: served_reach_sentence(kind, organisation)

  defp served_reach_sentence(:empty, organisation),
    do: ApiaryWeb.Edition.Core.gateway_reach_sentence(:empty, organisation)

  defp served_reach_sentence(kind, organisation) do
    case clients_served(organisation) do
      0 -> ApiaryWeb.Edition.Core.gateway_reach_sentence(kind, organisation)
      clients -> reach_sentence(kind, organisation.name, clients)
    end
  end

  defp client_reach_sentence(:intro, name, operator),
    do:
      gettext(
        "Machines and pools in any workspace of %{organisation} can use the gateways listed here and the gateways of %{operator}. Owners and admins of %{operator}, its operator, manage them.",
        organisation: name,
        operator: operator
      )

  defp client_reach_sentence(:empty, name, operator),
    do:
      gettext(
        "Machines and pools in %{organisation}'s workspaces can use the gateways of %{operator}, its operator, whose owners and admins also add gateways here.",
        organisation: name,
        operator: operator
      )

  defp reach_sentence(:intro, name, clients),
    do:
      ngettext(
        "Machines and pools in any workspace of %{organisation} and of its %{number} client can use the gateways added here. A workspace can also add gateways that only its machines and pools use.",
        "Machines and pools in any workspace of %{organisation} and of its %{number} clients can use the gateways added here. A workspace can also add gateways that only its machines and pools use.",
        clients,
        organisation: name,
        number: ApiaryWeb.Format.number(clients)
      )

  defp reach_sentence(:who_can_use, name, clients),
    do:
      ngettext(
        "Machines and pools in any workspace of %{organisation} and of its %{number} client can use it.",
        "Machines and pools in any workspace of %{organisation} and of its %{number} clients can use it.",
        clients,
        organisation: name,
        number: ApiaryWeb.Format.number(clients)
      )

  defp reach_sentence(:default_row, name, _clients),
    do:
      gettext(
        "The default gateway for workspaces in %{organisation}, and in its clients where neither the workspace nor the client sets one.",
        organisation: name
      )

  # The number of clients an operator's gateways serve: none while the operator does not
  # own its clients, and for an organisation that is no operator.
  defp clients_served(%{id: id} = organisation) when is_binary(id) do
    if ApiaryPro.Tenants.operator?(organisation),
      do: length(ApiaryPro.Gateways.served_organisations(id)),
      else: 0
  end

  defp clients_served(_organisation), do: 0

  # While the operator owns its clients, a client's nodes, node pools and access keys are
  # its operator's owners' and admins' to manage (`ApiaryPro.Access`): the nodes' pages
  # say so in place of the core's sentence of who may.
  @impl true
  def nodes_managed_by_sentence(organisation) do
    with %{name: operator} <- operator_owning(organisation),
         do:
           gettext(
             "Owners and admins of %{operator}, its operator, manage the machines, pools and access keys here.",
             operator: operator
           )
  end

  # While the operator owns its clients, nobody in a client is made an owner: the
  # invitation's description says that the client's admins change the new member's level,
  # and Admin's hint says what an admin manages in a client; the core's words otherwise,
  # the Owner and Member hints among them.
  @impl true
  def people_sentence(about, scope, bindings)
      when about in [:invite_by_mail, :invite_by_link, {:level_hint, :admin}] do
    if operated?(scope), do: people_words(about, bindings)
  end

  def people_sentence(_about, _scope, _bindings), do: nil

  defp people_words(:invite_by_mail, %{workspace: workspace, organisation: organisation}),
    do:
      gettext(
        "We email them a link that works for seven days and brings them into %{workspace} as a member; %{organisation}'s admins can change their level afterwards.",
        workspace: workspace,
        organisation: organisation
      )

  defp people_words(:invite_by_link, %{workspace: workspace, organisation: organisation}),
    do:
      gettext(
        "You get a link to send them yourself. It works for seven days and brings them into %{workspace} as a member; %{organisation}'s admins can change their level afterwards.",
        workspace: workspace,
        organisation: organisation
      )

  defp people_words({:level_hint, :admin}, _bindings),
    do: gettext("Manages members and settings")

  # The operator that owns `organisation`, a client, while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`); nil otherwise.
  defp operator_owning(%{id: id} = organisation) when is_binary(id) do
    with true <- ApiaryPro.Flags.operator_infrastructure?(),
         operator_id when is_binary(operator_id) <- ApiaryPro.Tenants.operator_id(organisation) do
      Apiary.Repo.get(Apiary.Organisations.Organisation, operator_id)
    else
      _not_operated -> nil
    end
  end

  defp operator_owning(_organisation), do: nil

  # Whether the scope's organisation is a client its operator owns, while the operator
  # owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`).
  defp operated?(%Scope{organisation: %{} = organisation}),
    do: ApiaryPro.Flags.operator_infrastructure?() and ApiaryPro.Tenants.client?(organisation)

  defp operated?(_scope), do: false

  defp set_by_sentence(scope) do
    with %{name: operator} <- owning_operator(scope),
         do:
           gettext("Set by your operator, %{operator}. Ask them to change it.",
             operator: operator
           )
  end

  # The operator that owns the scope's organisation, a client, while the operator owns its
  # clients (`ApiaryPro.Flags.operator_infrastructure?/0`); nil otherwise.
  defp owning_operator(scope) do
    if operated?(scope), do: ApiaryPro.Operators.operator_of(scope)
  end

  # While the operator owns its clients, an entry in a client made by a person who acted
  # there through its operator names the operator beside them, as the entry recorded it
  # (`ApiaryPro.Edition`'s `audit_details/3`); the core's words otherwise.
  @impl true
  def activity_actor(
        %Apiary.Audit.Entry{id: entry_id, details: %{"via_operator_id" => operator_id}},
        %{actor: %{kind: :person} = actor, names: names, scope: scope}
      ) do
    with true <- ApiaryPro.Flags.operator_infrastructure?(),
         true <- ApiaryPro.Tenants.client?(scope.organisation),
         operator when is_binary(operator) <- names.organisations[operator_id] do
      # The core's cell, "you" where the reader is the actor, with the operator in its
      # words.
      words = %{
        actor
        | text: gettext("%{person} of %{operator}", person: actor.text, operator: operator)
      }

      ApiaryWeb.Activity.Actor.actor(%{
        __changed__: nil,
        id: "entry-#{entry_id}-actor-person",
        actor: %{edition: nil, words: words}
      })
    else
      _not_named -> nil
    end
  end

  def activity_actor(_entry, _assigns), do: nil

  @impl true
  def activity_describer, do: ApiaryProWeb.ActivityDescriber

  @impl true
  def gettext_backend, do: ApiaryProWeb.Gettext

  # The first segments of the instance's paths that the edition keeps beyond the core's: its
  # former paths (`/organisations`, `/workspace`). The edition's routes take no first
  # segment the core's do not.
  @instance ~w(organisations workspace)

  # Other names reserved at the top level. Not `organisation`: it is the slug a name
  # with no letter or digit gets.
  @instance_reserved ~w(
    about account accounts app auth billing blog help home login logout oauth operator
    register signin signout signup static status support workspaces www
  )

  # The edition's pages of an organisation, the second segment of `/:org/…`: an operator's
  # clients, Instance settings' former addresses, which lead to it, a
  # client's policy requests and the organisation's policy.
  @organisation_pages ~w(clients instance policy policy-requests)

  # The names no slug may be beyond the core's, which the core adds to its list
  # (`ApiaryWeb.ReservedSlugs`).
  @impl true
  def reserved_slugs do
    %{
      instance: @instance ++ @instance_reserved,
      organisation: @organisation_pages
    }
  end

  # The Instance admins guide is for whoever runs the instance: `mix docs` builds it into the
  # tree for instance admins alone (`ApiaryWeb.DocsController`).
  @impl true
  def admin_guides, do: ["admin.md"]

  # Secrets and variables, for a person who reads the organisation's secrets and
  # variables, its two tabs each a page (`ApiaryProWeb.SettingsLive.SecretsAndVariables`),
  # leading to Secrets; or, where the feature is off, for whoever changes the keys of the
  # organisation's model providers under `provider.write` where `factory` and `secrets` are
  # shown, a page of those keys alone, with no tabs; then Ownership, for a person who may act
  # on it
  # (`ApiaryProWeb.SettingsLive.Ownership`).
  @impl true
  def settings_tabs(scope),
    do: secrets_and_variables_tab(scope) ++ ownership_tab(scope)

  defp secrets_and_variables_tab(%Scope{organisation: %{}} = scope) do
    if SecretsAndVariables.shown?(scope) do
      [
        %Entry{
          key: SecretsAndVariables.section(),
          label: SecretsAndVariables.title(),
          icon: "hero-lock-closed",
          path: fn organisation, _workspace ->
            SecretsAndVariables.tab_path(organisation, :secrets)
          end,
          place: :organisation
        }
      ]
    else
      []
    end
  end

  defp secrets_and_variables_tab(_scope), do: []

  defp ownership_tab(scope) do
    if Ownership.tab?(scope) do
      [
        %Entry{
          key: :ownership,
          label: gettext("Ownership"),
          icon: "hero-key",
          path: fn organisation, _workspace -> ~p"/#{organisation}/settings/ownership" end,
          place: :organisation
        }
      ]
    else
      []
    end
  end

  @impl true
  def slot(:notices, assigns), do: ApiaryProWeb.Notices.notices(assigns)
  def slot(:organisation_heading, assigns), do: ApiaryProWeb.Slots.workspaces_heading(assigns)
  def slot(:workspaces_heading, assigns), do: ApiaryProWeb.Slots.workspaces_heading(assigns)
  def slot(:members_heading, assigns), do: ApiaryProWeb.Slots.members_heading(assigns)
  def slot(:member_access, assigns), do: ApiaryProWeb.Slots.member_access(assigns)
  def slot(:member_actions, assigns), do: ApiaryProWeb.Slots.member_actions(assigns)

  # While the operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`), its
  # policy requests are not there, and the policy page says nothing of them.
  def slot(:policy_notices, assigns) do
    unless ApiaryPro.Flags.operator_infrastructure?(),
      do: ApiaryProWeb.Slots.policy_notices(assigns)
  end

  def slot(_name, _assigns), do: nil
end
