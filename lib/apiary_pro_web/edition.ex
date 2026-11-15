defmodule ApiaryProWeb.Edition do
  @moduledoc """
  The edition's web side (`ApiaryWeb.Edition`): what it adds to the core's pages.

  - The organisation's sidebar: **Policy**, the organisation's policy, in the first group,
    the one without a heading, after the core's entries there, where the feature is on
    (`ApiaryProWeb.PolicyLive.Organisation`), "Organisation policy" in the palette.
  - The Instance level's sections after the core's General and before its Mail and
    Configuration (`instance_sections/1`): **Organisations** and **Accounts**, for the
    instance admins (`ApiaryWeb.Access.on_mount/4`, `:instance`). The Qory Apiary menu's
    Instance settings leads to General, and the sections lead on to them.
  - The organisation menu's **New organisation**, where the instance opens a kind of
    organisation to the person (`ApiaryPro.Organisations.new_organisation_kinds/1`), and
    each workspace a person reaches through an operator, under that operator; **New workspace** in
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
    core's type cards, `/:org/workspaces/new`; each member's workspaces on its People page, with the way to change them
    (`ApiaryProWeb.Slots`).
  - The `:notices` slot: that an instance admin reads it and changes nothing, and the offer of an organisation's ownership to the admin it names
    (`ApiaryProWeb.Notices`).
  - The audit log's words for the edition's actions (`ApiaryProWeb.ActivityDescriber`).
  - The edition's sentences, in its catalogues (`ApiaryProWeb.Gettext`).
  - Where the level above a workspace's policy is read and changed
    (`above_policy_link/1`): the organisation's policy page, for the workspace's policy
    pages and Network access, where the organisation has a policy, and its New rule page
    for an owner, where a host only the organisation can allow is led.
  - The switcher's places: the workspaces a person reaches through an operator; and what
    the pages say to a person who reads an organisation as an instance admin or as a
    person of the operator of one of its workspaces (`ApiaryProWeb.Readers`).
  - The names no slug may be beyond the core's (`ApiaryWeb.ReservedSlugs`): the edition's pages
    of an organisation, its former top-level paths, and other reserved top-level names.
  """

  use ApiaryWeb.Edition
  use ApiaryProWeb, :verified_routes
  use Gettext, backend: ApiaryProWeb.Gettext

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias ApiaryPro.{OperatedPlace, Transfers}
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
      }
    ]
  end

  # Instance settings' Organisations and Accounts, for the instance admins: the second column
  # of the Instance level, before the core's Configuration.
  @impl true
  def instance_sections(scope), do: ApiaryProWeb.InstanceLive.Components.sections(scope)

  # Sign-up, on Instance settings › Configuration, after the core's Invitations.
  @impl true
  def configuration_parts(_scope), do: [ApiaryProWeb.InstanceLive.SignUpPart]

  # Whether the instance's admins offer the reader the organisation's ownership, which the
  # notices say on every page (`ApiaryProWeb.Notices`). Such an offer is made while no
  # owner may act, so the offer is read only then.
  @impl true
  def nav_counts(scope) do
    if ownership_offered?(scope),
      do: %{ownership_offer: true},
      else: %{}
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

  # The organisation menu lists an organisation where the person is a member of it, with
  # the workspaces the membership reaches. Under an operator the person belongs to, it lists
  # each workspace they reach only through that operator.
  @impl true
  def switcher_place(%OperatedPlace{membership: membership, operated: operated}) do
    workspaces = member_workspaces(membership)
    reached = MapSet.new(workspaces || [], & &1.id)
    {workspaces, Enum.reject(operated, fn {_id, w} -> MapSet.member?(reached, w.id) end)}
  end

  def switcher_place(place), do: {place.workspaces, []}

  defp member_workspaces(nil), do: nil
  defp member_workspaces(%{workspaces: workspaces}) when is_list(workspaces), do: workspaces
  defp member_workspaces(_membership), do: []

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

  # An operator is deleted once it operates no workspace, and a workspace once it has no
  # operator (`ApiaryPro.Deletion.refusal/2`).
  @impl true
  def refusal_sentence(:has_operated_workspaces),
    do: gettext("An operator that operates a workspace cannot be deleted.")

  def refusal_sentence(:operated),
    do: gettext("A workspace with an operator cannot be deleted.")

  def refusal_sentence(_reason), do: nil

  # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, an entry made in an operated
  # workspace by a person who acted there through its operator names the operator beside
  # them, as the entry recorded it (`ApiaryPro.Edition`'s `audit_details/3`); the core's
  # words otherwise.
  @impl true
  def activity_actor(
        %Apiary.Audit.Entry{id: entry_id, details: %{"via_operator_id" => operator_id}},
        %{actor: %{kind: :person} = actor, names: names}
      ) do
    with true <- ApiaryPro.Flags.operator_infrastructure?(),
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

  # The edition's pages of an organisation, the second segment of `/:org/…`: Instance
  # settings' former addresses, which lead to it, and the organisation's policy.
  @organisation_pages ~w(instance policy)

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

  def slot(_name, _assigns), do: nil
end
