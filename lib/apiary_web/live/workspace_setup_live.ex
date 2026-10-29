defmodule ApiaryWeb.WorkspaceSetupLive do
  # The workspace set-up: `/:org/set-up` (`:show`), the page every organisation with no
  # workspace in use lands on (`ApiaryWeb.UserAuth.signed_in_path/1`), and
  # `/:org/workspaces/new` (`:new`), where an owner adds a workspace. Both show the type
  # cards first, then the flow that sets up a workspace of the type picked, in the set-up's
  # frame with the progress indicator (`ApiaryWeb.SetUpComponents.frame/1`).
  #
  # **The type cards.** One card per domain of `Apiary.Lingo.Domain.choices/0` that has a
  # card's words (`card_words/1`): Software alone. Each card has the
  # type's name (`c:Apiary.Lingo.Domain.type_name/0`), what you do there, what you
  # connect, and Choose, which opens the flow with `?type=<name>`. No indicator shows:
  # the count starts after a card is picked. `/:org/set-up` shows them while the
  # organisation has no workspace in use, to a person `workspace.create` allows there
  # (`Apiary.Access`), and a person whom it does not allow reads who sets it up
  # (`c:Apiary.Edition.first_workspace_waiting_line/1`), with the indicator where the
  # edition lists 2 steps or more (the core lists them none) and the context where the
  # edition has a line (`c:Apiary.Edition.set_up_context/2`), under the edition's title
  # (`c:Apiary.Edition.set_up_title/2`). `/:org/workspaces/new` is a page only for a
  # person `workspace.create` allows; where the organisation has as many workspaces as the
  # edition allows (`c:Apiary.Edition.limits/0`), the page shows that line in place of
  # the cards.
  #
  # **The flow.** `?step=<id>` opens a step of the flow (`Apiary.WorkspaceSetup.flow/0`);
  # without one, or with one the person does not see, the first step that is not done.
  # Before the workspace exists, the flow opens Name, whatever the step. The steps of a
  # workspace that exists take `&workspace=<slug>`, its slug, which the scope resolves as
  # it does a workspace's pages; without it, the workspace the scope has. Before the
  # workspace exists, `&type=<name>` is the type picked; a flow with no type shows the
  # cards. `/:org/set-up` sets up a new workspace while the organisation has none in use,
  # else the scope's workspace; `/:org/workspaces/new` a new workspace until Name creates
  # it, then the steps go on at `/:org/set-up`. Once every step of a workspace is done,
  # `/:org/set-up` without a step sends the person to the workspace's first page. The
  # steps, in order, each as `Apiary.WorkspaceSetup.done?/3` counts it:
  #
  #   * Name: the Name field, "Main" for the organisation's first workspace, and Create
  #     workspace, with the type picked: on `/:org/set-up`, the organisation's first
  #     workspace (`Apiary.Organisations.create_first_workspace/2`, which returns
  #     `{:error, :exists}` for a second, under the organisation's lock), on
  #     `/:org/workspaces/new` any other (`Apiary.Organisations.create_workspace/2`); once
  #     the workspace exists, its name, read only, with Continue;
  #   * Work sources and Destinations, with the `factory` feature: a card per live grant
  #     of the organisation's connections (`Apiary.WorkspaceSetup.cards/4`,
  #     `ApiaryWeb.IntegrationComponents.grant_card/1`), of the adapters with items for
  #     Work sources and those with `targets` true for Destinations: the adapter's title
  #     and the account's, how many of the grant's collections are chosen for the
  #     workspace, of how many, or All, and Choose, which opens the chooser
  #     (`ApiaryWeb.ChooseCollectionsLive`). An adapter connected with no grant yet shows
  #     Connected. Connect another source, or Connect another destination, lists the
  #     instance's configured adapters that serve the type
  #     (`Apiary.Adapters.list_configured/1`) and that the organisation has not connected,
  #     each Connecting… while its connection is pending, with Connect, the Install of
  #     Organisation settings › Integrations (`ApiaryWeb.IntegrationComponents.install_form/1`),
  #     whose return leads back to the step (`ApiaryWeb.ConnectSession.back?/1`); it is
  #     open while the step has no card. In the context column, for each adapter whose
  #     Connect can be pressed and whose guide has steps for connecting it
  #     (`Apiary.Adapters.guide/2`), those steps. Skip while the step is not done, else
  #     Continue. A person whom `adapter.connect` does not allow sees the adapters with no
  #     Connect, and who may connect (`ApiaryWeb.Access.who_may/3`); a person whom
  #     `collection.assign` does not allow sees who may. The page listens to the
  #     organisation's collections and connections
  #     (`Apiary.Adapters.Collections.subscribe/1`) and reads the step again on each change;
  #   * Model, with the features `factory` and `secrets`: three choices. Key: each model
  #     provider of the organisation with a key that reaches the workspace (applies to
  #     every workspace or lists it), by its name, to reuse, and Add a key, whose
  #     Provider, Key and, for a provider that needs one, Address add a model provider for
  #     the workspace (`Apiary.Connections.create_provider/3` with `:workspace`): the key
  #     is a secret of the workspace, and the provider reaches that workspace alone. Where
  #     the edition shows it (`c:Apiary.Edition.scope_setting?/1`), Add a key has the
  #     setting "Available to every workspace in <organisation>", off; on, it adds the
  #     provider for the organisation, reaching every workspace, its key a secret of the
  #     organisation (`Apiary.Connections.reach_at_add/3`). Where the edition shows that
  #     setting, the providers to reuse that apply to every workspace come first in Key,
  #     under "Shared in <organisation>", each marked "every workspace"; with none, Key
  #     has no heading. With
  #     no provider to reuse, Add a key alone, open. Runtime, the runtimes the
  #     provider serves (`Apiary.Kinds.Providers.serve/2`), as text where there is one.
  #     Default model, the models suggested for the provider and runtime
  #     (`Apiary.ModelChoices.suggestions/2`). Continue saves the workspace's choice
  #     (level 5, `Apiary.ModelChoices.put_choice/4`) with the provider, its default key,
  #     the runtime and the model. The line under the form shows where to change the
  #     model and the key: Workspace settings for a key that is a secret of the workspace,
  #     Organisation settings for one of the organisation, and the model alone for one of
  #     the organisation where the edition shows no organisation secrets
  #     (`c:Apiary.Edition.organisation_secrets/2`). The key is never kept in an
  #     assign: its field is left out of the page's patches (`phx-update="ignore"`). A
  #     save needs `model_choice.write` on the workspace, and Add a key needs
  #     `provider.write` too. A person who may not save, or who may not add a key where
  #     there is none to reuse, sees who may;
  #   * Harness, with the `factory` feature: the two harness choices
  #     (`ApiaryWeb.HarnessComponents.choices/1`), the saved one chosen, else the harness
  #     the organisation shares, else the Qory harness. In a workspace whose domain has
  #     harness files (`Apiary.Lingo.Domain.harness_file?/1`), the Qory harness shows
  #     that a target's harness file comes first. The linked repositories of a harness
  #     repository are read once the step opens, outside the page's process, once per
  #     page, and listed under Source, a choice with a search box. Where the listing read
  #     every linked repository and lists none, the line that none has a stack shows in
  #     place of Source. Continue saves the choice (`Apiary.Stacks.Sources.choose/3`) and
  #     goes on, or goes on where it is the saved one; a harness repository is read
  #     outside the page's process while Continue shows Saving, and a read that failed
  #     says why. Where the
  #     edition shows it (`c:Apiary.Edition.scope_setting?/1`), the step has the setting
  #     "Available to every workspace in <organisation>", off; on, Continue saves the
  #     choice as the harness the organisation shares (`shared: true`), which a workspace
  #     with no choice reuses. While the organisation shares one, the shared harness
  #     comes first, under "Shared in <organisation>" and marked "every workspace", chosen
  #     while the workspace reuses it. Continue with it chosen goes on with nothing saved
  #     where the workspace reuses it, and else removes the workspace's choice
  #     (`Apiary.Stacks.Sources.reuse_shared/1`); with a usual choice, it saves the
  #     workspace's choice, the same as the shared one or not. While the organisation
  #     shares one, a second is refused, and the step says to choose the shared harness
  #     or turn the setting off. Under the
  #     choices, Targets lists the workspace's destinations, the rows the Destinations
  #     step ticked, each with Workspace default or the stack chosen for it
  #     (`Apiary.Stacks.Sources.targets_chosen/1`,
  #     `ApiaryWeb.HarnessComponents.targets/1`), and Change. Change opens the
  #     destination's form: Workspace default, which removes its stack, the Qory harness,
  #     or a harness source among the groups of Workflow's Source, then a stack of it. A
  #     source's stacks are read outside the page's process, and a read cancels the one
  #     before it. Save stores the choice
  #     (`Apiary.Stacks.Sources.choose_target/3`), outside the page's process for a
  #     harness source, and a refusal says why; while it saves, no other Change opens. A
  #     person whom `harness.save` does not allow sees the choices disabled, the
  #     destinations with no Change, and who may;
  #   * Machines, with the `factory` feature: the node pools that serve the workspace's
  #     runs, each with its state (`Apiary.WorkspaceSetup.pools/1`): the workspace's
  #     pools, or the instance's pool while it has none. A ready pool shows its gateway's
  #     name; a pool that is not ready shows the reason
  #     (`t:Apiary.WorkspaceSetup.not_ready_reason/0`): no pool, no active key, a choice
  #     of Direct, no gateway, a chosen gateway that the pool's runs may not go through,
  #     or a gateway with no active key. Under a pool that is not ready: for the
  #     instance's pool, Check the nodes, to `/instance/nodes`, for an instance admin; for
  #     a pool of the workspace, its name links to its page for a person whom
  #     `access_key.create_code` allows on it. Anyone else reads who acts
  #     (`c:Apiary.Edition.machines_who_may/3`). While the workspace has no pool, a person
  #     whom `node.create` allows on it chooses: Shared, the instance's pool, chosen
  #     first, or A pool for the workspace, with the line that the shared pool then stops
  #     serving its runs, and Add node pool, which makes a pool of the workspace
  #     (`Apiary.Nodes.create_node/2`) named `Apiary.WorkspaceSetup.pool_name/1`. Where
  #     another node of the workspace has that name, no pool is made, and the line under
  #     Add node pool says to rename that node. Anyone else sees the instance's pool, read
  #     only, shown chosen. Once the workspace has one pool, a person whom `node.delete`
  #     allows on it sees the same choice, the workspace's pool chosen, and the pool's
  #     line under it. Shared opens on its row the confirmation of the removal, with the
  #     line that the pool's machines stop taking runs where a machine enrolled on it
  #     (`Apiary.AccessKeys.active_key?/1`), Remove pool, which deletes the pool
  #     (`Apiary.Nodes.delete_node/2`), and Cancel. Then the instance's pool serves the
  #     workspace again, shown chosen. Where the instance has no pool, Shared shows not
  #     ready for no pool, cannot be chosen, and the step offers no removal. Otherwise, once the workspace has a pool, its pools
  #     show with no choice, and a pool that is the only one shows chosen. With 2 pools or
  #     more, the step offers no removal. On each line of a pool whose
  #     `access_key.create_code` allows the person, while the pool has fewer than 2
  #     active keys, Get the command, or Get a new command while a code of it is
  #     outstanding, makes a code (`Apiary.AccessKeys.create_enrolment_code/3`), and the
  #     line shows the enrol command (`ApiaryWeb.NodeComponents.enrol_command/3`) with
  #     Copy while that code is outstanding, kept in the page's process alone, as the
  #     pool's Access key tab keeps it, until the person leaves the step. Under the
  #     command, the step shows the line that the command runs on the Linux machine with
  #     Docker that runs the workspace's runs and joins that machine to the pool, then the
  #     command that installs qory, with Copy. The step reads
  #     the pools again once the first outstanding code expires, and as a machine enrols
  #     a key on a pool of the workspace or a code of it is cancelled
  #     (`Apiary.AccessKeys.subscribe/2`, once per pool);
  #   * Test run, with the `factory` feature: Say hi to your agent and Run the test
  #     (`Apiary.WorkItems.take_in_test/2`) once a pool serves the workspace
  #     (`c:Apiary.Edition.machines_ready/1`); before, the line that runs need a ready
  #     pool, whose See Machines links to the Machines step, and no Run the test. Then the
  #     test run's state (`Apiary.WorkspaceSetup.test_run/2`): waiting,
  #     running, passed, or one of four failures, read again as the workspace's queue and
  #     its runs change (`Apiary.Dispatches.subscribe/1`, `Apiary.Runs.subscribe/1`) and
  #     once a wait for a machine passes. Once it passed, Go to the workspace. A person
  #     whom `work_item.take_in` does not allow sees who may.
  #
  # Every step has Back to the step before it in the indicator, where that step has a
  # page: Name has none, so Back never leads to the cards or the instance's steps.
  # The page listens to the organisation's workspaces
  # (`Apiary.Organisations.subscribe_workspaces/1`): once its first workspace is made, by
  # anyone else, the page opens `/:org/set-up` again. The steps of the `factory` feature
  # are left out of the module reference with the module.
  @moduledoc false

  use ApiaryWeb, :live_view

  alias Apiary.{
    Access,
    Adapters,
    Connections,
    Dispatches,
    Edition,
    ModelChoices,
    Organisations,
    Runs,
    WorkItems,
    WorkspaceSetup
  }

  alias Apiary.Adapters.Collections
  alias Apiary.Adapters.Connections, as: AdapterConnections
  alias Apiary.Kinds.{Provider, Providers, Runtimes}
  alias Apiary.Lingo.Domain
  alias Apiary.Runs.Run
  alias Apiary.Stacks.Sources

  alias ApiaryWeb.{
    HarnessComponents,
    IntegrationComponents,
    OverviewComponents,
    SetUpComponents
  }

  alias ApiaryWeb.ProviderLive.Index, as: ProviderPage

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Organisations.subscribe_workspaces(scope)
      # Refused to a person who may not read the organisation's adapters: their page
      # shows the step as it opened.
      _subscribed = Collections.subscribe(scope)
    end

    {:ok,
     assign(socket,
       view: nil,
       flow: nil,
       step: nil,
       listening: false,
       timer: nil,
       attempt: 0,
       test_notice: nil,
       test_form: test_form(gettext("Hi! Where are you running?")),
       linked: nil,
       linked_complete: false,
       listing: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope
    organisation = scope.organisation
    creates = Access.can?(scope, :"workspace.create", organisation)

    case socket.assigns.live_action do
      :new ->
        if not creates, do: raise(ApiaryWeb.NotFound)
        {:noreply, open_new(socket, params, :new)}

      :show ->
        cond do
          not Organisations.has_workspace?(organisation) and creates ->
            {:noreply, open_new(socket, params, :set_up)}

          not Organisations.has_workspace?(organisation) ->
            {:noreply, assign_waiting(socket)}

          is_nil(scope.workspace) ->
            {:noreply, push_navigate(socket, to: ~p"/#{organisation}")}

          # A patch to another workspace: the scope resolves it as the page mounts.
          is_binary(params["workspace"]) and params["workspace"] != scope.workspace.slug ->
            {:noreply,
             push_navigate(socket,
               to: ~p"/#{organisation}/set-up?#{Map.take(params, ~w(step workspace))}"
             )}

          true ->
            workspace = scope.workspace

            flow =
              SetUpComponents.flow(
                organisation,
                Domain.for_workspace(workspace),
                workspace,
                :set_up
              )

            {:noreply, open_flow(socket, flow, params["step"])}
        end
    end
  end

  # A new workspace: the cards, or the flow of the type `?type=` is set to.
  defp open_new(socket, params, page) do
    organisation = socket.assigns.current_scope.organisation

    case card_domain(params["type"]) do
      nil ->
        assign_cards(socket, page)

      domain ->
        open_flow(
          socket,
          SetUpComponents.flow(organisation, domain, nil, page, type: true),
          params["step"]
        )
    end
  end

  defp assign_cards(socket, page) do
    scope = socket.assigns.current_scope

    assign(socket,
      view: :cards,
      page: page,
      flow: nil,
      step: nil,
      page_title: gettext("What will this workspace do?"),
      cards: for(domain <- Domain.choices(), card = card_words(domain), do: {domain, card}),
      limit: page == :new and at_limit?(scope)
    )
  end

  # Whether the organisation has as many workspaces in use as the edition allows.
  defp at_limit?(scope) do
    case Edition.limits().workspaces do
      :unlimited -> false
      limit -> length(Organisations.list_workspaces(scope)) >= limit
    end
  end

  # A person who may not create the organisation's first workspace waits: the core lists
  # them no step, so the page shows no indicator unless the edition lists steps
  # (`c:Apiary.Edition.set_up_steps/2`).
  defp assign_waiting(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      view: :waiting,
      flow: nil,
      step: nil,
      steps: Edition.set_up_steps(scope, []),
      page_title: Edition.set_up_title(scope, nil)
    )
  end

  ## The cards

  # The words of a domain's card, nil for a domain without one, which shows no card. A
  # person reads a card's line where they pick a type, in any locale, so the line is in the
  # `workspace type` context and keeps the type's words.
  defp card_words(Domain.Software) do
    %{
      what: pgettext("workspace type", "Agents change code in your repositories."),
      connect: gettext("You connect: where work comes from, where changes go, a model.")
    }
  end

  defp card_words(_domain), do: nil

  # The domain whose name is `name` and that has a card, nil for none.
  defp card_domain(name) when is_binary(name) do
    Enum.find(Domain.choices(), &(&1.name() == name and card_words(&1) != nil))
  end

  defp card_domain(_name), do: nil

  defp card_path(organisation, :set_up, domain),
    do: ~p"/#{organisation}/set-up?#{[type: domain.name()]}"

  defp card_path(organisation, :new, domain),
    do: ~p"/#{organisation}/workspaces/new?#{[type: domain.name()]}"

  ## The flow

  # The step `?step=` is set to, among the steps the person sees, else the first that is not
  # done. Before the workspace exists, Name.
  defp open_flow(socket, %{workspace: nil} = flow, _step_param),
    do: assign_step(socket, flow, :name)

  defp open_flow(socket, flow, step_param) do
    scope = socket.assigns.current_scope
    plain = SetUpComponents.steps_for(scope, nil, flow: flow)
    flow_ids = WorkspaceSetup.flow()
    ids = for %{id: id} <- plain, id in flow_ids, do: id
    named = Enum.find(ids, &(Atom.to_string(&1) == step_param))
    pending = Enum.find(plain, &(&1.id in ids and &1.state != :done))

    case named || (pending && pending.id) do
      nil -> push_navigate(socket, to: Layouts.workspace_landing(scope))
      current -> assign_step(socket, flow, current)
    end
  end

  defp assign_step(socket, flow, step) do
    scope = socket.assigns.current_scope
    steps = SetUpComponents.steps_for(scope, step, flow: flow)
    next = SetUpComponents.next_step(steps, step)

    socket
    |> assign(
      view: :flow,
      flow: flow,
      step: step,
      steps: steps,
      title: SetUpComponents.flow_title(flow),
      page_path: page_path(flow),
      next_path: next && next.path,
      page_title: heading(step, flow),
      refusal: nil
    )
    |> load_step()
  end

  defp page_path(%{organisation: organisation, page: :new}),
    do: ~p"/#{organisation}/workspaces/new"

  defp page_path(%{organisation: organisation, page: :set_up}), do: ~p"/#{organisation}/set-up"

  # The indicator and the step's data, read again.
  defp reload(%{assigns: %{view: :flow, flow: flow, step: step}} = socket) do
    steps = SetUpComponents.steps_for(socket.assigns.current_scope, step, flow: flow)

    socket
    |> assign(steps: steps)
    |> load_step()
  end

  defp reload(socket), do: socket

  defp heading(:name, _flow), do: gettext("Name this workspace")

  defp heading(:sources, flow),
    do: gettext("Where does work for %{workspace} come from?", workspace: flow.workspace.name)

  defp heading(:destinations, flow),
    do:
      gettext("Which targets may runs in %{workspace} change?",
        workspace: flow.workspace.name
      )

  defp heading(:model, flow),
    do: gettext("Which model do runs in %{workspace} use?", workspace: flow.workspace.name)

  defp heading(:harness, flow),
    do: gettext("Which harness do runs in %{workspace} use?", workspace: flow.workspace.name)

  defp heading(:machines, flow),
    do: gettext("Which machines run the runs in %{workspace}?", workspace: flow.workspace.name)

  defp heading(:test, _flow), do: gettext("Run a test")

  ## Each step's data

  # The cards of the step's grants; the configured adapters for the step, those connected
  # with no card yet, and those not connected, each with Connect. `may` and `who_may` are
  # of the chooser's Save (`collection.assign`); `may_connect` and `who_connects` of
  # Connect (`adapter.connect`).
  defp load_step(%{assigns: %{step: step}} = socket) when step in [:sources, :destinations] do
    %{current_scope: scope, flow: flow} = socket.assigns
    role = if step == :sources, do: :items, else: :targets
    may_connect = Access.can?(scope, :"adapter.connect", scope.organisation)

    adapters =
      for adapter <- Adapters.list_configured(flow.domain),
          if(role == :items, do: Adapters.items?(adapter), else: adapter.targets == true),
          do: adapter

    connecting =
      for {adapter_id, %{state: :pending}} <- AdapterConnections.live_by_adapter(scope),
          into: MapSet.new(),
          do: adapter_id

    connected = WorkspaceSetup.connected_ids(flow.organisation, flow.domain, role)
    cards = WorkspaceSetup.cards(scope, flow.domain, step, flow.workspace)
    carded = MapSet.new(cards, & &1.adapter.id)

    assign(socket,
      cards: cards,
      adapters: adapters,
      waiting: for(a <- adapters, a.id in connected, a.id not in carded, do: a),
      unconnected: for(a <- adapters, a.id not in connected, do: a),
      connecting: connecting,
      ready:
        for(
          a <- adapters,
          may_connect,
          IntegrationComponents.ready?(a),
          into: MapSet.new(),
          do: a.id
        ),
      may: Access.can?(scope, :"collection.assign", scope.organisation),
      who_may: IntegrationComponents.who_assigns(scope, Enum.map(cards, & &1.adapter)),
      may_connect: may_connect,
      who_connects:
        ApiaryWeb.Access.who_may(
          scope,
          :"adapter.connect",
          gettext("Only owners and admins change the integrations of the organisation.")
        ),
      sending: nil,
      done: step_done?(flow, step)
    )
  end

  # `providers` are the ones to reuse, of which the first `shared_keys` are shown as shared
  # (`split_shared/2`); `may_add` is of Add a key (`provider.write`), and `may` of a save
  # (`model_choice.write` on the workspace) with a key to choose.
  defp load_step(%{assigns: %{step: :model}} = socket) do
    %{current_scope: scope, flow: flow} = socket.assigns
    {shared, others} = split_shared(scope, reusable_providers(scope, flow.workspace))
    providers = shared ++ others
    may_add = Access.can?(scope, :"provider.write", scope.organisation)
    choice = workspace_choice(scope, flow.workspace)

    socket
    |> assign(
      may:
        Access.can?(scope, :"model_choice.write", flow.workspace) and
          (may_add or providers != []),
      may_add: may_add,
      who_may:
        ApiaryWeb.Access.who_may(
          scope,
          :"provider.write",
          gettext("Only owners and admins add a model key.")
        ),
      providers: providers,
      shared_keys: length(shared),
      choice: choice,
      # Whether the edition shows the organisation's secrets: the core shows none.
      organisation_secrets: Edition.organisation_secrets(scope, :read) != {:error, :not_found},
      done: step_done?(flow, :model)
    )
    |> assign_model_form(model_params(providers, choice), [])
  end

  defp load_step(%{assigns: %{step: :name}} = socket) do
    %{current_scope: scope, flow: flow} = socket.assigns

    name =
      if Organisations.has_workspace?(scope.organisation),
        do: "",
        else: Organisations.default_workspace_name()

    assign(socket,
      form:
        to_form(%{"name" => if(flow.workspace, do: flow.workspace.name, else: name)},
          as: "workspace"
        )
    )
  end

  defp load_step(%{assigns: %{step: :harness}} = socket) do
    %{current_scope: scope, flow: %{workspace: workspace} = flow} = socket.assigns
    chosen = Sources.chosen(workspace)
    may = Access.can?(scope, :"harness.save", workspace)
    targets = harness_targets(scope, flow)
    shared = shared_harness(scope, chosen)
    params = HarnessComponents.form_params(chosen, socket.assigns.linked)

    socket
    |> assign(
      may: may,
      who_may:
        ApiaryWeb.Access.who_may(
          scope,
          :"harness.save",
          gettext("Only owners and admins change this.")
        ),
      chosen: chosen,
      shared_harness: shared,
      qory: HarnessComponents.qory(chosen, workspace),
      saving: false,
      harness_refusal: nil,
      harness_file: Domain.harness_file?(workspace),
      harness_targets: targets,
      harness_assigned: if(may, do: Sources.assigned(scope), else: []),
      target_qory: HarnessComponents.qory(%{}, workspace),
      target_edit: kept_edit(socket.assigns[:target_edit], targets, may),
      done: step_done?(socket.assigns.flow, :harness)
    )
    |> assign_harness_form(
      if(shared && chosen.shared, do: %{params | "choice" => "shared"}, else: params)
    )
    |> list_linked()
  end

  # Each pool's line, who may act on a pool that is not ready, and who acts for anyone
  # else. `makes_pool` is of Add node pool (`node.create`); `pool_codes` has, for each pool
  # of the workspace whose command the person may get (`access_key.create_code`), its
  # outstanding codes and its keys. The command got stays while its code is outstanding,
  # on a read again of the step; an entry to the step, which assigns `step` anew, starts
  # without it. The choice and the line on a taken name stay while the workspace has no
  # pool. `shared_line` is the line of the instance's pool, for a person who keeps the
  # choice once the
  # workspace has its one pool (`keeps_choice?/2`); `pool_removable` is the pool that
  # Shared offers to remove (`removable_pool/2`); the confirmation of its removal stays open
  # on a read again of the step (`pool_removing`), and an entry to the step starts with it
  # closed. The page listens to each pool of the workspace once (`pool_listened`), and reads
  # the step again as the first outstanding code expires (`pool_timer`).
  defp load_step(%{assigns: %{step: :machines}} = socket) do
    %{current_scope: scope, flow: %{workspace: workspace}} = socket.assigns
    pools = WorkspaceSetup.pools(workspace)
    workspace_pools = for %{instance: false, pool: pool} <- pools, do: pool
    socket = listen_to_pools(socket, workspace_pools)

    pool_codes =
      for pool <- workspace_pools,
          Access.can?(scope, :"access_key.create_code", pool),
          into: %{} do
        {pool.id,
         %{
           codes: Apiary.AccessKeys.list_enrolment_codes(scope, pool),
           keys: Apiary.AccessKeys.list_for_node(scope, pool)
         }}
      end

    issued =
      case socket.assigns[:pool_issued] do
        %{pool_id: pool_id, row: %{id: code_id}} = issued when is_map_key(pool_codes, pool_id) ->
          if not Phoenix.Component.changed?(socket, :step) and
               Enum.any?(pool_codes[pool_id].codes, &(&1.id == code_id)),
             do: issued

        _none ->
          nil
      end

    shared_line = if keeps_choice?(scope, workspace_pools), do: WorkspaceSetup.instance_line()
    removable = removable_pool(workspace_pools, shared_line)

    removing =
      if removable && not Phoenix.Component.changed?(socket, :step) &&
           socket.assigns[:pool_removing] == removable.id,
         do: removable.id

    assign(socket,
      pools: pools,
      workspace_pools: workspace_pools,
      pool_removable: removable,
      pool_removing: removing,
      shared_line: shared_line,
      instance_admin: Access.instance_admin?(scope),
      enrols: MapSet.new(Map.keys(pool_codes)),
      makes_pool: Access.can?(scope, :"node.create", workspace),
      pool_codes: pool_codes,
      pool_issued: issued,
      pool_choice: if(workspace_pools == [], do: socket.assigns[:pool_choice] || "shared"),
      pool_taken: if(workspace_pools == [], do: socket.assigns[:pool_taken]),
      who_may: %{
        instance: Edition.machines_who_may(scope, workspace, :instance),
        workspace: Edition.machines_who_may(scope, workspace, :workspace)
      },
      done: step_done?(socket.assigns.flow, :machines)
    )
    |> schedule_pool_expiry(pool_codes)
  end

  defp load_step(%{assigns: %{step: :test}} = socket) do
    %{current_scope: scope, flow: %{workspace: workspace}} = socket.assigns
    socket = listen(socket)
    test = WorkspaceSetup.test_run(workspace, DateTime.utc_now())

    # The line to wait goes away once no test run is in progress.
    notice =
      if match?(%{dispatch_run: %{state: state}} when state != :ended, test),
        do: socket.assigns.test_notice

    socket
    |> assign(
      test: test,
      test_state: test && test.state,
      machines: Edition.machines_ready(workspace),
      may: Access.can?(scope, :"work_item.take_in", workspace),
      who_may:
        ApiaryWeb.Access.who_may(
          scope,
          :"work_item.take_in",
          gettext("Only owners, admins and members run the test.")
        ),
      test_notice: notice
    )
    |> wait_for_machine()
  end

  # Whether the step `id` of `flow` is done, by its rule: the indicator marks the current
  # step as current, done or not.
  defp step_done?(flow, id),
    do: WorkspaceSetup.done?(id, flow.organisation, {flow.domain, flow.workspace})

  # Once the Test run step opens, the page listens to the workspace's queue and runs.
  defp listen(%{assigns: %{listening: false}} = socket) do
    if connected?(socket) do
      scope = socket.assigns.current_scope
      Dispatches.subscribe(scope.workspace.id)
      Runs.subscribe(scope)
      assign(socket, :listening, true)
    else
      socket
    end
  end

  defp listen(socket), do: socket

  # While the test run waits for a machine, the step reads it again once the wait passes
  # `Apiary.WorkspaceSetup.machine_wait_seconds/0`, and shows that no machine took it.
  defp wait_for_machine(%{assigns: %{timer: timer}} = socket) do
    if timer, do: Process.cancel_timer(timer)

    case socket.assigns.test do
      %{state: :waiting, dispatch_run: dispatch_run} ->
        at = DateTime.add(dispatch_run.queued_at, WorkspaceSetup.machine_wait_seconds(), :second)
        wait = DateTime.diff(at, DateTime.utc_now(), :millisecond)
        assign(socket, :timer, Process.send_after(self(), :setup_tick, max(wait, 0) + 1_000))

      _other ->
        assign(socket, :timer, nil)
    end
  end

  ## The Harness step's form

  defp assign_harness_form(socket, params),
    do: assign(socket, form: to_form(params, as: :harness))

  # The harness the organisation shares (`Apiary.Stacks.Sources.shared/1`), where the
  # edition shows the setting that shares one (`c:Apiary.Edition.scope_setting?/1`); nil
  # else, and for none. The shared one of `chosen` saves a read.
  defp shared_harness(scope, chosen) do
    cond do
      not Edition.scope_setting?(scope) -> nil
      chosen.shared -> chosen
      true -> Sources.shared(scope.organisation)
    end
  end

  # The choice the Harness form's `params` come to: `:shared` for the harness the
  # organisation shares, where the step lists it (`shared`); else
  # `ApiaryWeb.HarnessComponents.choice/2`.
  defp harness_choice(%{"choice" => "shared"}, _linked, %{} = _shared), do: :shared
  defp harness_choice(params, linked, _shared), do: HarnessComponents.choice(params, linked)

  # The linked repositories, read once per page, outside the page's process, for a person
  # who may save.
  defp list_linked(%{assigns: %{listing: false, may: true}} = socket) do
    if connected?(socket) do
      scope = socket.assigns.current_scope

      socket
      |> assign(:listing, true)
      |> start_async(:harness_linked, fn -> Sources.linked(scope) end)
    else
      socket
    end
  end

  defp list_linked(socket), do: socket

  # The workspace's destinations, the rows of the Destinations step's list it ticked, one
  # per target, each with the stack chosen for it, nil for none.
  defp harness_targets(scope, %{workspace: workspace, domain: domain}) do
    chosen = Sources.targets_chosen(workspace)

    for {_adapter, rows} <- WorkspaceSetup.collections(scope, domain, :destinations),
        row <- rows,
        WorkspaceSetup.ticked?(:destinations, row, workspace) do
      %{collection: collection} = row
      target = %{system: collection.target_system, path: collection.target_path}

      %{
        id: collection.public_id,
        title: collection.title,
        target: target,
        chosen: chosen[{target.system, target.path}]
      }
    end
    |> Enum.uniq_by(& &1.target)
  end

  # The form of a destination stays open as the step reads again, while the destination
  # is listed and the person may save.
  defp kept_edit(%{id: id} = edit, targets, true) do
    case Enum.find(targets, &(&1.id == id)) do
      nil -> nil
      target -> %{edit | target: target.target}
    end
  end

  defp kept_edit(_edit, _targets, _may), do: nil

  # A form of `target` with Workspace default chosen, or its saved choice.
  defp new_edit(target) do
    choice =
      case target.chosen do
        nil -> "default"
        %{choice: :qory} -> "qory"
        %{choice: :repository} -> "repository"
      end

    %{
      id: target.id,
      target: target.target,
      choice: choice,
      source_id: "",
      address: "",
      address_error: nil,
      source: nil,
      stacks: nil,
      reading: false,
      read_error: nil,
      stack: "0",
      ref: "main",
      refusal: nil,
      saving: false
    }
  end

  # The form's values sent: the choice, the stack and the branch or tag, then a source
  # chosen anew or an address typed.
  defp pick_target(socket, edit, params) do
    choice =
      if params["choice"] in ~w(default qory repository), do: params["choice"], else: edit.choice

    edit = %{
      edit
      | choice: choice,
        stack: params["stack"] || edit.stack,
        ref: params["ref"] || edit.ref,
        refusal: nil
    }

    source_id = params["source"] || edit.source_id

    cond do
      choice != "repository" -> assign(socket, :target_edit, edit)
      source_id != edit.source_id -> pick_source(socket, edit, source_id, params["address"])
      source_id == "address" -> target_address(socket, edit, params["address"])
      true -> assign(socket, :target_edit, edit)
    end
  end

  defp pick_source(socket, edit, "address", text) do
    edit = %{
      edit
      | source_id: "address",
        source: nil,
        stacks: nil,
        read_error: nil,
        reading: false
    }

    socket |> cancel_async(:target_read) |> target_address(edit, text || edit.address)
  end

  defp pick_source(socket, edit, id, _text) do
    %{linked: linked, harness_assigned: assigned} = socket.assigns

    case Enum.find((linked || []) ++ assigned, &(&1.id == id)) do
      nil ->
        socket
        |> cancel_async(:target_read)
        |> assign(:target_edit, %{
          edit
          | source_id: "",
            source: nil,
            stacks: nil,
            read_error: nil,
            reading: false
        })

      source ->
        read_target(socket, edit, source)
    end
  end

  # The address typed, checked, and read when it passes; nothing is read again for the
  # same address.
  defp target_address(socket, edit, text) when is_binary(text) do
    cond do
      text == edit.address and edit.source != nil ->
        assign(socket, :target_edit, edit)

      String.trim(text) == "" ->
        socket
        |> cancel_async(:target_read)
        |> assign(:target_edit, %{
          edit
          | address: text,
            address_error: nil,
            source: nil,
            stacks: nil,
            read_error: nil,
            reading: false
        })

      true ->
        case Sources.address(text) do
          {:ok, source} ->
            read_target(socket, %{edit | address: text, address_error: nil}, source)

          {:error, error} ->
            socket
            |> cancel_async(:target_read)
            |> assign(:target_edit, %{
              edit
              | address: text,
                address_error: translate_error(error),
                source: nil,
                stacks: nil,
                read_error: nil,
                reading: false
            })
        end
    end
  end

  defp target_address(socket, edit, _text), do: assign(socket, :target_edit, edit)

  # `source` chosen: its stacks read outside the page's process; a later choice cancels
  # this read.
  defp read_target(socket, edit, source) do
    scope = socket.assigns.current_scope
    id = if source.kind == :address, do: "address", else: source.id

    socket
    |> assign(:target_edit, %{
      edit
      | source_id: id,
        source: source,
        stacks: nil,
        stack: "0",
        read_error: nil,
        reading: true
    })
    |> cancel_async(:target_read)
    |> start_async(:target_read, fn -> {source.id, source.git, Sources.read(scope, source)} end)
  end

  # The answer to a save of the stack `choice` for a destination.
  defp target_saved(socket, _choice, {:ok, _stack}) do
    %{current_scope: scope, flow: flow} = socket.assigns
    assign(socket, target_edit: nil, harness_targets: harness_targets(scope, flow))
  end

  defp target_saved(socket, _choice, {:error, :forbidden}),
    do:
      socket
      |> assign(:target_edit, nil)
      |> load_step()
      |> put_flash(:error, socket.assigns.who_may)

  defp target_saved(%{assigns: %{target_edit: %{} = edit}} = socket, choice, {:error, reason}) do
    {source, ref} =
      case choice do
        {:stack, source, _stack, ref} -> {source, ref}
        _other -> {nil, nil}
      end

    organisation = socket.assigns.flow.organisation.name

    case HarnessComponents.refusal_words(reason, source, ref, organisation) do
      nil -> put_flash(socket, :error, gettext("Nothing was changed. Try again."))
      words -> assign(socket, :target_edit, %{edit | refusal: words})
    end
  end

  defp target_saved(socket, _choice, {:error, _reason}),
    do: put_flash(socket, :error, gettext("Nothing was changed. Try again."))

  ## The Model step's form

  # The organisation's model providers with a key that reach `workspace`: those that apply
  # to every workspace, and those that list it.
  defp reusable_providers(scope, workspace) do
    case Connections.list_providers(scope) do
      {:ok, providers} ->
        Enum.filter(
          providers,
          &(keys(&1) > 0 and
              (&1.applies_to == "all" or workspace.id in Connections.workspace_ids_of(&1)))
        )

      {:error, _reason} ->
        []
    end
  end

  # `providers` as `{shared, others}`, each in the order given: shared are those that apply
  # to every workspace, where the edition shows the setting that makes them
  # (`c:Apiary.Edition.scope_setting?/1`); none where it does not.
  defp split_shared(scope, providers) do
    if Edition.scope_setting?(scope),
      do: Enum.split_with(providers, &(&1.applies_to == "all")),
      else: {[], providers}
  end

  # The workspace's choice (level 5), nil for none.
  defp workspace_choice(scope, workspace) do
    case ModelChoices.list_choices(scope) do
      {:ok, choices} ->
        Enum.find(
          choices,
          &(&1.workspace_id == workspace.id and is_nil(&1.target_id) and is_nil(&1.workflow))
        )

      {:error, _reason} ->
        nil
    end
  end

  # The form's first values: the provider of the workspace's choice, with its runtime and
  # model, where it is one to reuse; else the first provider to reuse; else Add a key.
  defp model_params(providers, choice) do
    case {providers, choice && Enum.find(providers, &(&1.id == choice.connection_id))} do
      {_providers, %{} = provider} ->
        %{"source" => provider.public_id, "runtime" => choice.runtime, "model" => choice.model_id}

      {[provider | _rest], nil} ->
        %{"source" => provider.public_id}

      {[], nil} ->
        %{"source" => "add", "provider" => first_provider()}
    end
  end

  defp first_provider, do: Providers.list() |> hd() |> Map.fetch!(:name)

  # The key `params` chose: a provider to reuse, or `:add`, for a person who may add one.
  # Anything else is the first provider to reuse, and `:add` where there is none.
  defp model_source(params, %{providers: providers, may_add: may_add}) do
    reused = Enum.find(providers, &(&1.public_id == params["source"]))

    cond do
      reused -> reused
      params["source"] == "add" and may_add -> :add
      true -> List.first(providers) || :add
    end
  end

  # The form of the Model step, from what was sent but the key, with `errors` on its
  # fields; the key's field is always empty. The provider is the catalogue's for Add a
  # key, the description of the provider to reuse for one.
  defp assign_model_form(socket, params, errors) do
    source = model_source(params, socket.assigns)

    # Add a key chosen after a provider to reuse: the form sent no Provider yet.
    params =
      if source == :add, do: Map.put_new(params, "provider", first_provider()), else: params

    chosen =
      case source do
        :add -> catalogue(params["provider"])
        provider -> described(provider)
      end

    runtimes =
      if chosen, do: Enum.filter(Runtimes.list(), &Providers.serves?(chosen, &1)), else: []

    runtime = Enum.find(runtimes, &(&1.name == params["runtime"])) || List.first(runtimes)

    models =
      cond do
        is_nil(runtime) -> []
        source == :add -> ModelChoices.suggestions(chosen, runtime)
        true -> ModelChoices.suggestions(source, runtime)
      end

    model = Enum.find(models, &(&1.id == params["model"])) || List.first(models)

    kept =
      if source == :add,
        do:
          Map.take(params, [
            "provider",
            "everywhere" | ProviderPage.address_names(params["provider"])
          ]),
        else: %{}

    values =
      Map.merge(kept, %{
        "source" => source_value(source),
        "key" => "",
        "runtime" => runtime && runtime.name,
        "model" => model && model.id
      })

    values = Enum.reduce(errors, values, fn {field, _}, v -> Map.put_new(v, "#{field}", "") end)

    assign(socket,
      form: to_form(values, as: :model, errors: errors),
      source: source,
      everywhere: everywhere?(socket.assigns.current_scope, source, params),
      chosen: chosen,
      runtimes: runtimes,
      runtime: runtime,
      models: models
    )
  end

  # Whether Add a key adds the provider for every workspace: the setting shown and on.
  defp everywhere?(scope, :add, params),
    do: params["everywhere"] == "true" and Apiary.Edition.scope_setting?(scope)

  defp everywhere?(_scope, _source, _params), do: false

  # Whether the key `source` chose is a secret of the workspace: Add a key adds one, unless
  # it adds the provider for every workspace, and a provider to reuse links one or the
  # organisation's secret.
  defp workspace_key?(:add, everywhere), do: not everywhere

  defp workspace_key?(%{secret: %{workspace_id: workspace_id}}, _everywhere),
    do: is_binary(workspace_id)

  defp workspace_key?(_provider, _everywhere), do: false

  # Where to change the default model and the key `source` chose: Workspace settings for a
  # key that is a secret of the workspace, Organisation settings for one of the
  # organisation, where the edition shows the organisation's secrets
  # (`organisation_secrets`); the model alone where it does not.
  defp later_line(source, everywhere, organisation_secrets) do
    cond do
      workspace_key?(source, everywhere) ->
        gettext(
          "You can change the default model later in Workspace settings › Model, and the key in Workspace settings › Secrets and variables."
        )

      organisation_secrets ->
        gettext(
          "You can change the default model later in Workspace settings › Model, and the key in Organisation settings › Secrets and variables."
        )

      true ->
        gettext("You can change the default model later in Workspace settings › Model.")
    end
  end

  # The value of Key's option for `source`.
  defp source_value(:add), do: "add"
  defp source_value(provider), do: provider.public_id

  # The options of Key: each provider to reuse, by its name, then Add a key for a person
  # who may add one.
  defp source_options(providers, may_add) do
    reused = for provider <- providers, do: {provider.name, provider.public_id}
    if may_add, do: reused ++ [{gettext("Add a key"), "add"}], else: reused
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :options, :list, required: true, doc: "Key's options, `{words, value}`"
  attr :shared, :integer, required: true, doc: "how many of `options`, the first, are shared"
  attr :organisation, :string, required: true

  # Key, one radio group as `input/1` draws one: the first `shared` options under "Shared
  # in <organisation>", each marked "every workspace", then the others. With no shared
  # option, no heading.
  defp key_choice(assigns) do
    {shared, others} = assigns.options |> Enum.with_index() |> Enum.split(assigns.shared)
    errors = Enum.map(assigns.field.errors, &translate_error/1)

    assigns =
      assign(assigns,
        id: "set-up-model-source",
        shared_options: shared,
        other_options: others,
        errors: errors
      )

    ~H"""
    <fieldset
      id={@id}
      class="fieldset"
      aria-invalid={@errors != [] && "true"}
      aria-describedby={
        @errors != [] && Enum.map_join(1..length(@errors), " ", &key_error_id(@id, &1))
      }
    >
      <legend class="mb-1 text-[13px]/[18px] font-medium">{gettext("Key")}</legend>
      <div
        :if={@shared_options != []}
        id={"#{@id}-shared"}
        role="group"
        aria-labelledby={"#{@id}-shared-h"}
        class="grid gap-1"
      >
        <p id={"#{@id}-shared-h"} class="text-[12.5px]/[18px] font-medium text-muted">
          {gettext("Shared in %{organisation}", organisation: @organisation)}
        </p>
        <.key_option
          :for={{option, index} <- @shared_options}
          id={@id}
          field={@field}
          option={option}
          index={index}
          shared
        />
      </div>
      <.key_option
        :for={{option, index} <- @other_options}
        id={@id}
        field={@field}
        option={option}
        index={index}
      />
      <p
        :for={{msg, i} <- Enum.with_index(@errors, 1)}
        id={key_error_id(@id, i)}
        class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error"
      >
        <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
        {msg}
      </p>
    </fieldset>
    """
  end

  attr :id, :string, required: true
  attr :field, Phoenix.HTML.FormField, required: true
  attr :option, :any, required: true
  attr :index, :integer, required: true
  attr :shared, :boolean, default: false

  defp key_option(assigns) do
    ~H"""
    <label
      for={"#{@id}-#{@index}"}
      class="inline-flex w-fit cursor-pointer items-center gap-2 text-[13.5px]/5 max-md:min-h-10"
    >
      <input
        type="radio"
        id={"#{@id}-#{@index}"}
        name={@field.name}
        value={elem(@option, 1)}
        checked={to_string(@field.value) == elem(@option, 1)}
        class="radio radio-sm radio-primary"
      />
      <span>
        {elem(@option, 0)}<span :if={@shared} class="text-muted"> · {gettext("every workspace")}</span>
      </span>
    </label>
    """
  end

  # The id of Key's error `n`, counted from 1, as `input/1` numbers a field's errors.
  defp key_error_id(id, 1), do: "#{id}-error"
  defp key_error_id(id, n), do: "#{id}-error-#{n}"

  defp catalogue(name) do
    case Providers.fetch(name) do
      {:ok, provider} -> provider
      :error -> nil
    end
  end

  defp described(provider) do
    case Connections.provider(provider) do
      {:ok, description} -> description
      {:error, _changed} -> nil
    end
  end

  defp keys(%{secret: %{values: values}}) when is_list(values), do: length(values)
  defp keys(_provider), do: 0

  # Adds the provider with its key for Add a key; the provider to reuse, else. The key is
  # a secret of the flow's workspace, which Name made before this step, and the provider
  # reaches that workspace alone (`Apiary.Connections.create_provider/3`, `:workspace`);
  # with the setting shown and on, the provider is the organisation's, reaching every
  # workspace, its key a secret of the organisation (`Apiary.Connections.reach_at_add/3`).
  defp model_provider(:add, scope, flow, params) do
    with %Provider{} = provider <- catalogue(params["provider"]) || {:error, :provider_unknown},
         runtime = Enum.find(Runtimes.list(), &(&1.name == params["runtime"])),
         :ok <- if(runtime, do: serves(provider, runtime), else: :ok) do
      scope = %{scope | workspace: flow.workspace}

      attrs = %{
        "provider" => provider.name,
        "keys" => [%{"value_id" => "key-1", "value" => params["key"] || ""}],
        "settings" => Map.new(ProviderPage.address_names(provider.name), &{&1, params[&1] || ""})
      }

      case Connections.reach_at_add(scope, flow.workspace, params["everywhere"] == "true") do
        %{"applies_to" => "all"} = reach ->
          Connections.create_provider(scope, Map.merge(attrs, reach))

        %{"applies_to" => "selected"} ->
          Connections.create_provider(scope, attrs, :workspace)
      end
    end
  end

  defp model_provider(provider, _scope, _flow, _params), do: {:ok, provider}

  defp serves(provider, runtime) do
    case ModelChoices.serves(provider, runtime) do
      :ok -> :ok
      {:error, {message, bindings}} -> {:error, {:serves, {message, bindings}}}
    end
  end

  ## Events

  @impl true
  def handle_event(
        "install",
        %{"integration" => public_id},
        %{assigns: %{step: step, may_connect: true}} = socket
      )
      when step in [:sources, :destinations] do
    if Enum.any?(socket.assigns.unconnected, &(&1.public_id == public_id)),
      do: {:noreply, assign(socket, :sending, public_id)},
      else: {:noreply, socket}
  end

  def handle_event(
        "choose_model",
        %{"model" => params},
        %{assigns: %{step: :model, may: true}} = socket
      ),
      do: {:noreply, assign_model_form(socket, params, [])}

  def handle_event(
        "save_model",
        %{"model" => params},
        %{assigns: %{step: :model, may: true}} = socket
      ) do
    scope = socket.assigns.current_scope
    socket = assign(socket, attempt: socket.assigns.attempt + 1, refusal: nil)
    source = model_source(params, socket.assigns)

    unchanged? =
      case {source, socket.assigns.choice} do
        {%{id: id}, %{connection_id: id, runtime: runtime, model_id: model}} ->
          runtime == params["runtime"] and model == params["model"]

        _other ->
          false
      end

    cond do
      params["source"] == "add" and not socket.assigns.may_add ->
        {:noreply, socket |> load_step() |> put_flash(:error, socket.assigns.who_may)}

      # A provider sent that is not one to reuse, such as one removed since the page read
      # them: nothing is saved.
      source_value(source) != params["source"] ->
        {:noreply,
         socket |> load_step() |> put_flash(:error, gettext("Nothing was changed. Try again."))}

      unchanged? ->
        {:noreply, go_on(socket)}

      true ->
        save_model(socket, scope, source, params)
    end
  end

  def handle_event(
        "create",
        %{"workspace" => params},
        %{assigns: %{step: :name, flow: %{workspace: nil}}} = socket
      ) do
    %{current_scope: scope, flow: flow} = socket.assigns
    name = if is_binary(params["name"]), do: params["name"], else: ""

    attrs = %{"name" => name, "domain" => flow.domain.name()}

    # On `/:org/set-up` the workspace is the organisation's first: of two owners at once,
    # one creates it, under the organisation's lock.
    created =
      case flow.page do
        :set_up -> Organisations.create_first_workspace(scope, attrs)
        :new -> Organisations.create_workspace(scope, attrs)
      end

    case created do
      {:ok, workspace} ->
        flow = SetUpComponents.flow(flow.organisation, flow.domain, workspace, :set_up)
        next = next_id(scope, flow, :name)

        to =
          if next,
            do: SetUpComponents.flow_path(flow, next),
            else: ~p"/#{flow.organisation}/#{workspace}"

        # Off the Name step, so the broadcast this page caused navigates no second time.
        {:noreply, socket |> assign(:view, :created) |> push_navigate(to: to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          for {field, error} <- changeset.errors, field in [:name, :slug], do: {:name, error}

        {:noreply,
         assign(socket,
           form: to_form(%{"name" => name}, as: "workspace", errors: errors, action: :insert),
           refusal: if(marked_name?(scope, name), do: :name_taken)
         )}

      {:error, :limit} ->
        {:noreply, assign(socket, :refusal, :limit)}

      # Someone else created the first workspace a moment before: the page as it opens now.
      {:error, :exists} ->
        {:noreply, push_navigate(socket, to: ~p"/#{flow.organisation}/set-up")}

      {:error, _reason} ->
        {:noreply, push_navigate(socket, to: page_path(flow))}
    end
  end

  def handle_event(
        "choose_harness",
        %{"harness" => params},
        %{assigns: %{step: :harness, may: true}} = socket
      )
      when is_map(params) do
    params = HarnessComponents.fill(params, socket.assigns.chosen, socket.assigns.linked)
    {:noreply, socket |> assign(harness_refusal: nil) |> assign_harness_form(params)}
  end

  def handle_event(
        "save_harness",
        %{"harness" => params},
        %{assigns: %{step: :harness, may: true, saving: false}} = socket
      )
      when is_map(params) do
    %{current_scope: scope, linked: linked, chosen: chosen} = socket.assigns
    socket = assign_harness_form(socket, params)

    case harness_choice(params, linked, socket.assigns.shared_harness) do
      nil ->
        {:noreply, socket}

      # The harness the organisation shares: nothing to save where the workspace reuses
      # it; else the workspace's choice goes, so it reuses the shared one.
      :shared ->
        if chosen.shared,
          do: {:noreply, go_on(socket)},
          else: {:noreply, harness_saved(socket, :shared, Sources.reuse_shared(scope))}

      choice ->
        shared = share?(scope, params)

        # The workspace's saved choice goes on with no save, unless the setting is on. For
        # a workspace that reuses the shared harness: while the step lists that harness,
        # a usual choice is saved as the workspace's, even one equal to the shared
        # harness; where the step does not list it, a choice equal to it goes on.
        no_save? =
          if chosen.shared,
            do: is_nil(socket.assigns.shared_harness),
            else: not shared

        cond do
          HarnessComponents.unchanged?(choice, chosen) and no_save? ->
            {:noreply, go_on(socket)}

          match?({:repository, _source, _ref}, choice) ->
            {:noreply,
             socket
             |> assign(saving: true, harness_refusal: nil)
             |> start_async(:harness_save, fn ->
               {choice, Sources.choose(scope, choice, shared: shared)}
             end)}

          true ->
            {:noreply,
             harness_saved(socket, choice, Sources.choose(scope, choice, shared: shared))}
        end
    end
  end

  def handle_event(
        "change_target",
        %{"id" => id},
        %{assigns: %{step: :harness, may: true}} = socket
      )
      when is_binary(id) do
    saving = match?(%{saving: true}, socket.assigns.target_edit)

    case Enum.find(socket.assigns.harness_targets, &(&1.id == id)) do
      # A save in flight finishes first, so its answer reaches its form.
      _target when saving ->
        {:noreply, socket}

      nil ->
        {:noreply, socket}

      target ->
        {:noreply, socket |> cancel_async(:target_read) |> assign(:target_edit, new_edit(target))}
    end
  end

  def handle_event(
        "cancel_target",
        _params,
        %{assigns: %{step: :harness, target_edit: %{saving: false}}} = socket
      ),
      do: {:noreply, socket |> cancel_async(:target_read) |> assign(:target_edit, nil)}

  def handle_event(
        "pick_target",
        %{"target_stack" => params},
        %{assigns: %{step: :harness, may: true, target_edit: %{saving: false} = edit}} = socket
      )
      when is_map(params),
      do: {:noreply, pick_target(socket, edit, params)}

  def handle_event(
        "save_target",
        %{"target_stack" => params},
        %{assigns: %{step: :harness, may: true, target_edit: %{saving: false} = edit}} = socket
      )
      when is_map(params) do
    scope = socket.assigns.current_scope
    choice = if params["choice"] in ~w(default qory repository), do: params["choice"]

    edit = %{
      edit
      | choice: choice || edit.choice,
        stack: params["stack"] || edit.stack,
        ref: params["ref"] || edit.ref,
        refusal: nil
    }

    socket = assign(socket, :target_edit, edit)

    case HarnessComponents.target_choice(edit) do
      nil ->
        {:noreply, socket}

      {:stack, _source, _stack, _ref} = choice ->
        target = edit.target

        {:noreply,
         socket
         |> assign(:target_edit, %{edit | saving: true})
         |> start_async(:target_save, fn ->
           {choice, Sources.choose_target(scope, target, choice)}
         end)}

      choice ->
        {:noreply,
         target_saved(socket, choice, Sources.choose_target(scope, edit.target, choice))}
    end
  end

  def handle_event("run_test", params, %{assigns: %{step: :test, may: true}} = socket) do
    line =
      case params do
        %{"test" => %{"line" => line}} -> line
        _other -> nil
      end

    cond do
      not is_binary(line) -> {:noreply, socket}
      is_nil(socket.assigns.machines) -> {:noreply, reload(socket)}
      true -> run_test(socket, line)
    end
  end

  # The Machines step's choice between the instance's pool and a pool for the workspace,
  # while the workspace has none.
  def handle_event(
        "choose_pool",
        %{"pool" => %{"choice" => choice}},
        %{assigns: %{step: :machines, makes_pool: true, workspace_pools: []}} = socket
      )
      when choice in ["shared", "workspace"],
      do: {:noreply, assign(socket, pool_choice: choice, pool_taken: nil)}

  # Once the workspace has its pool, for a person who may remove it: Shared opens the
  # confirmation of the removal on the Shared row, and the workspace's pool closes it.
  def handle_event(
        "choose_pool",
        %{"pool" => %{"choice" => choice}},
        %{assigns: %{step: :machines, pool_removable: %{id: id}}} = socket
      )
      when choice in ["shared", "workspace"],
      do: {:noreply, assign(socket, pool_removing: if(choice == "shared", do: id))}

  # Cancel of the confirmation: the workspace's pool stays chosen.
  def handle_event(
        "keep_pool",
        _params,
        %{assigns: %{step: :machines, pool_removable: %{}}} = socket
      ),
      do: {:noreply, assign(socket, pool_removing: nil)}

  # Remove pool: the workspace's pool is deleted (`Apiary.Nodes.delete_node/2`), which
  # revokes its keys and cancels its outstanding codes, and the instance's pool serves
  # the workspace again, shown chosen. Only while the confirmation of that pool is open.
  # The step reads again first: where the pool is no longer the one it offers to remove,
  # as after a second pool was added elsewhere, nothing is deleted, and the step shows as
  # read again.
  def handle_event(
        "remove_pool",
        _params,
        %{assigns: %{step: :machines, pool_removable: %{id: id}, pool_removing: id}} = socket
      ) do
    case reload(socket) do
      %{assigns: %{pool_removable: %{id: ^id} = pool, pool_removing: ^id}} = socket ->
        remove_pool(socket, pool)

      socket ->
        {:noreply, socket}
    end
  end

  # Add node pool: a pool of the workspace, named by `Apiary.WorkspaceSetup.pool_name/1`.
  # Where the workspace has a pool by then, from a second click or someone else, the step
  # reads again and shows it.
  def handle_event(
        "add_pool",
        _params,
        %{
          assigns: %{
            step: :machines,
            makes_pool: true,
            workspace_pools: [],
            pool_choice: "workspace"
          }
        } = socket
      ) do
    %{current_scope: scope, flow: %{workspace: workspace}} = socket.assigns
    name = WorkspaceSetup.pool_name(workspace)

    if WorkspaceSetup.instance_pool?(workspace) do
      case Apiary.Nodes.create_node(scope, %{kind: "pool", name: name}) do
        {:ok, _pool} ->
          {:noreply, socket |> assign(pool_taken: nil) |> reload()}

        {:error, %Ecto.Changeset{} = changeset} ->
          socket = reload(socket)

          cond do
            socket.assigns.workspace_pools != [] ->
              {:noreply, socket}

            pool_name_taken?(changeset) ->
              {:noreply, assign(socket, pool_taken: name)}

            true ->
              {:noreply, put_flash(socket, :error, gettext("Nothing was changed. Try again."))}
          end

        # Refused, or the workspace out of reach: the step as the person may see it now.
        {:error, _reason} ->
          {:noreply, reload(socket)}
      end
    else
      {:noreply, reload(socket)}
    end
  end

  # Get the command of a pool of the workspace: a code made at once, with the defaults, as
  # the pool's Access key tab makes it (`ApiaryWeb.NodeLive.AccessKey`), shown under the
  # pool's line while the code is outstanding. Only for a pool whose command the person
  # may get, while it has room for a key.
  def handle_event("pool_code", %{"pool" => public_id}, %{assigns: %{step: :machines}} = socket)
      when is_binary(public_id) do
    %{current_scope: scope, pool_codes: pool_codes} = socket.assigns
    pool = Enum.find(socket.assigns.workspace_pools, &(&1.public_id == public_id))

    cond do
      is_nil(pool) or not is_map_key(pool_codes, pool.id) ->
        {:noreply, reload(socket)}

      pool_at_limit?(pool_codes[pool.id].keys) ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("%{name} holds two keys already. Revoke one before you add another.",
             name: pool.name
           )
         )
         |> reload()}

      true ->
        pool_code(socket, scope, pool)
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The deletion of `pool`, the one the step offers to remove, as read again.
  defp remove_pool(socket, pool) do
    scope = socket.assigns.current_scope

    case Apiary.Nodes.delete_node(scope, pool) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> assign(pool_choice: "shared", pool_taken: nil, pool_removing: nil, pool_issued: nil)
         |> reload()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket |> put_flash(:error, gettext("Nothing was changed. Try again.")) |> reload()}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(pool_removing: nil)
         |> put_flash(
           :error,
           ApiaryWeb.Access.who_may(
             scope,
             :"node.delete",
             gettext("Only owners and admins delete nodes.")
           )
         )
         |> reload()}

      # Deleted already, or out of reach: the step as it is now.
      {:error, _reason} ->
        {:noreply, socket |> assign(pool_removing: nil) |> reload()}
    end
  end

  defp save_model(socket, scope, source, params) do
    case model_provider(source, scope, socket.assigns.flow, params) do
      {:ok, provider} ->
        # After a refusal of the choice, the form shows the provider as one to reuse.
        params = Map.put(params, "source", provider.public_id)

        case ModelChoices.put_choice(scope, :workspace, %{
               "provider" => provider.public_id,
               "key" => provider.default_value_id,
               "runtime" => params["runtime"],
               "model" => params["model"]
             }) do
          {:ok, _choice} -> {:noreply, go_on(socket)}
          {:error, reason} -> {:noreply, model_refused(load_step(socket), params, reason)}
        end

      {:error, {:serves, error}} ->
        {:noreply, assign_model_form(socket, params, provider: error)}

      {:error, :provider_unknown} ->
        {:noreply, assign_model_form(socket, params, provider: {"is invalid", []})}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_model_form(socket, params, ProviderPage.field_errors(changeset))}

      {:error, reason} ->
        {:noreply, model_refused(load_step(socket), params, reason)}
    end
  end

  # A refused choice, each reason on the step's field it is about, or a refusal of the
  # save in the flash.
  defp model_refused(socket, params, %Ecto.Changeset{} = changeset) do
    errors = for {field, error} <- changeset.errors, do: {model_field(field), error}
    assign_model_form(socket, params, errors)
  end

  defp model_refused(socket, _params, :forbidden),
    do: put_flash(socket, :error, socket.assigns.who_may)

  defp model_refused(socket, _params, _reason),
    do: put_flash(socket, :error, gettext("Nothing was changed. Try again."))

  defp go_on(socket),
    do: push_patch(socket, to: socket.assigns.next_path || socket.assigns.page_path)

  # Whether Continue saves the choice as the harness the organisation shares: the setting
  # shown and on.
  defp share?(scope, params),
    do: params["everywhere"] == "true" and Apiary.Edition.scope_setting?(scope)

  # The answer to a save of the harness choice `choice`.
  defp harness_saved(socket, _choice, {:ok, _stack}), do: go_on(socket)

  defp harness_saved(socket, _choice, {:error, :forbidden}),
    do: socket |> load_step() |> put_flash(:error, socket.assigns.who_may)

  # The organisation shares no harness any more: the step as it is now.
  defp harness_saved(socket, :shared, {:error, :not_shared}),
    do: socket |> load_step() |> put_flash(:error, gettext("Nothing was changed. Try again."))

  defp harness_saved(socket, _choice, {:error, :shared}) do
    words =
      gettext(
        "Choose the shared harness, or turn off “Available to every workspace in %{organisation}”. %{organisation} shares a harness already.",
        organisation: socket.assigns.flow.organisation.name
      )

    assign(socket, :harness_refusal, {:shared, words})
  end

  defp harness_saved(socket, choice, {:error, reason}) do
    {source, ref} =
      case choice do
        {:repository, source, ref} -> {source, ref}
        _other -> {nil, nil}
      end

    organisation = socket.assigns.flow.organisation.name

    case HarnessComponents.refusal_words(reason, source, ref, organisation) do
      nil -> put_flash(socket, :error, gettext("Nothing was changed. Try again."))
      words -> assign(socket, :harness_refusal, {reason, words})
    end
  end

  # A refusal of the choice, on the step's field it is about.
  defp model_field(field) when field in [:runtime, :model], do: field
  defp model_field(:effort), do: :model
  defp model_field(_field), do: :source

  # Whether a workspace of the organisation marked for deletion has the name `name`.
  defp marked_name?(scope, name),
    do: Enum.any?(Apiary.Deletion.list_marked_workspaces(scope), &(&1.name == String.trim(name)))

  defp next_id(scope, flow, id) do
    steps = SetUpComponents.steps_for(scope, id, flow: flow)

    case SetUpComponents.next_step(steps, id) do
      %{id: next} -> next
      nil -> nil
    end
  end

  defp run_test(socket, line) do
    scope = socket.assigns.current_scope

    case WorkItems.take_in_test(scope, line) do
      {:ok, _work_item} ->
        {:noreply, socket |> assign(test_notice: nil, test_form: test_form(line)) |> reload()}

      {:error, :test_running} ->
        {:noreply, socket |> assign(:test_notice, :test_running) |> reload()}

      {:error, %Ecto.Changeset{errors: errors}} ->
        {:noreply, assign(socket, test_notice: nil, test_form: test_form(line, errors[:title]))}

      {:error, :forbidden} ->
        {:noreply, socket |> reload() |> put_flash(:error, socket.assigns.who_may)}

      {:error, _reason} ->
        {:noreply,
         socket |> reload() |> put_flash(:error, gettext("Nothing was changed. Try again."))}
    end
  end

  # The form of Say hi to your agent, with the work item's refusal of the line, if any.
  defp test_form(line, error \\ nil) do
    if error,
      do: to_form(%{"line" => line}, as: "test", errors: [line: error], action: :insert),
      else: to_form(%{"line" => line}, as: "test")
  end

  @impl true
  def handle_async(:harness_linked, {:ok, {:ok, %{sources: linked} = listing}}, socket) do
    complete = listing.unread == 0 and listing.left_out == 0
    {:noreply, socket |> assign(:linked_complete, complete) |> harness_listed(linked)}
  end

  def handle_async(:harness_linked, _limited_or_exit, socket),
    do: {:noreply, harness_listed(socket, [])}

  def handle_async(
        :harness_save,
        {:ok, {choice, result}},
        %{assigns: %{step: :harness}} = socket
      ),
      do: {:noreply, socket |> assign(:saving, false) |> harness_saved(choice, result)}

  def handle_async(:harness_save, _exit_or_left, socket) do
    socket = assign(socket, :saving, false)

    if socket.assigns.step == :harness,
      do: {:noreply, put_flash(socket, :error, gettext("Nothing was changed. Try again."))},
      else: {:noreply, socket}
  end

  def handle_async(:target_read, {:ok, {id, git, result}}, socket) do
    case socket.assigns[:target_edit] do
      %{source: %{id: ^id, git: ^git}} = edit ->
        edit =
          case result do
            {:ok, stacks} -> %{edit | stacks: stacks, reading: false}
            {:error, reason} -> %{edit | read_error: reason, reading: false}
          end

        {:noreply, assign(socket, :target_edit, edit)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_async(:target_read, {:exit, _reason}, socket) do
    case socket.assigns[:target_edit] do
      %{reading: true} = edit ->
        {:noreply,
         assign(socket, :target_edit, %{edit | read_error: :unreadable, reading: false})}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_async(:target_save, {:ok, {choice, result}}, socket) do
    case socket.assigns[:target_edit] do
      %{saving: true} = edit when socket.assigns.step == :harness ->
        {:noreply,
         socket |> assign(:target_edit, %{edit | saving: false}) |> target_saved(choice, result)}

      # The step was left: it reads the saved stack when it opens again.
      %{saving: true} ->
        {:noreply, assign(socket, :target_edit, nil)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_async(:target_save, {:exit, _reason}, socket) do
    case socket.assigns[:target_edit] do
      %{saving: true} = edit ->
        {:noreply,
         socket
         |> assign(:target_edit, %{edit | saving: false})
         |> put_flash(:error, gettext("Nothing was changed. Try again."))}

      _other ->
        {:noreply, socket}
    end
  end

  # The linked repositories are read: a form with no repository chosen yet takes the
  # saved one, else the first.
  defp harness_listed(socket, linked) do
    socket = assign(socket, :linked, linked)

    case socket.assigns do
      %{step: :harness, form: %{params: params}, chosen: chosen} ->
        assign_harness_form(socket, HarnessComponents.fill(params, chosen, linked))

      _other ->
        socket
    end
  end

  @impl true
  # The organisation's first workspace was made by someone else while this page sets up
  # a new one: the page as it would open now.
  def handle_info({:workspace_created, _ids}, %{assigns: assigns} = socket) do
    new? =
      assigns.view in [:cards, :waiting] or
        match?(%{view: :flow, flow: %{workspace: nil}}, assigns)

    if new? and assigns.live_action == :show,
      do:
        {:noreply, push_navigate(socket, to: ~p"/#{assigns.current_scope.organisation}/set-up")},
      else: {:noreply, socket}
  end

  # A collection or a connection of the organisation changed: the step reads again.
  def handle_info({event, _ids}, socket)
      when event in [:collections_changed, :connection_changed],
      do: {:noreply, reload(socket)}

  # The workspace's queue changed, or the test run's wait for a machine ran out.
  def handle_info({Dispatches, :changed}, socket), do: {:noreply, reload(socket)}
  def handle_info(:setup_tick, socket), do: {:noreply, reload(socket)}

  # A change of the test run's registered run.
  def handle_info(
        {:run_changed, %Run{dispatch_run_id: id}},
        %{assigns: %{step: :test, test: %{dispatch_run: %{id: id}}}} = socket
      ),
      do: {:noreply, reload(socket)}

  # On the Machines step: a machine enrolled a key on a pool of the workspace, or a code
  # of one was cancelled (`Apiary.AccessKeys.subscribe/2`), or the first outstanding code
  # expired (`schedule_pool_expiry/2`): the step reads again.
  def handle_info({event, %{node_id: node_id}}, %{assigns: %{step: :machines}} = socket)
      when event in [:key_enrolled, :code_cancelled] do
    if Enum.any?(socket.assigns.workspace_pools, &(&1.id == node_id)),
      do: {:noreply, reload(socket)},
      else: {:noreply, socket}
  end

  def handle_info(:pool_codes_expire, %{assigns: %{step: :machines}} = socket),
    do: {:noreply, reload(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:organisation}
      sidebar={false}
    >
      <.cards :if={@view == :cards} {assigns} />
      <.waiting :if={@view == :waiting} scope={@current_scope} steps={@steps} title={@page_title} />
      <.flow_step :if={@view == :flow} {assigns} />
    </Layouts.app>
    """
  end

  defp cards(assigns) do
    ~H"""
    <SetUpComponents.frame>
      <SetUpComponents.heading>{gettext("What will this workspace do?")}</SetUpComponents.heading>
      <.notice :if={@limit} kind={:error}>
        <span id="set-up-limit">
          {gettext("%{organisation} may have no more workspaces.",
            organisation: @current_scope.organisation.name
          )}
        </span>
      </.notice>
      <ul :if={!@limit} id="set-up-cards" class="grid gap-3">
        <li
          :for={{domain, card} <- @cards}
          id={"set-up-card-#{domain.name()}"}
          class="grid gap-2 rounded-box border border-line bg-base-100 px-4 py-3"
        >
          <h2 class="font-semibold">{domain.type_name()}</h2>
          <p class="text-[13.5px]/5">{card.what}</p>
          <p class="text-[13.5px]/5 text-muted">{card.connect}</p>
          <div class="flex justify-end">
            <.button
              id={"set-up-card-#{domain.name()}-choose"}
              variant="primary"
              size="md"
              patch={card_path(@current_scope.organisation, @page, domain)}
            >
              {gettext("Choose")}
            </.button>
          </div>
        </li>
      </ul>
    </SetUpComponents.frame>
    """
  end

  attr :scope, :map, required: true
  attr :steps, :list, required: true
  attr :title, :string, required: true

  # The waiting line, for a person who may not create the organisation's first workspace.
  # The frame shows the steps where the edition lists 2 or more (the core lists none), and
  # the column About this step where the edition has a line for it
  # (`c:Apiary.Edition.set_up_context/2`).
  defp waiting(assigns) do
    assigns = assign(assigns, :context, Edition.set_up_context(assigns.scope, :workspace))

    ~H"""
    <SetUpComponents.frame steps={@steps} page={~p"/#{@scope.organisation}/set-up"}>
      <SetUpComponents.heading>{@title}</SetUpComponents.heading>
      <p id="set-up-waiting" class="text-sm/5 text-muted">
        {Edition.first_workspace_waiting_line(@scope.organisation)}
      </p>
      <:context :if={@context}>
        <p id="set-up-what">{@context}</p>
      </:context>
    </SetUpComponents.frame>
    """
  end

  defp flow_step(%{step: step} = assigns) when step in [:sources, :destinations] do
    # The step exists once the workspace does, on `/:org/set-up`.
    assigns =
      assign(assigns, back: "set-up:#{step}:workspace=#{assigns.flow.workspace.slug}")

    ~H"""
    <SetUpComponents.frame steps={@steps} title={@title} page={@page_path}>
      <SetUpComponents.heading>{@page_title}</SetUpComponents.heading>

      <ul :if={@cards != [] or @waiting != []} id="set-up-grants" class="grid gap-3">
        <IntegrationComponents.grant_card
          :for={card <- @cards}
          id={"set-up-grant-#{card.grant.public_id}"}
          card={card}
          list={@step}
          workspace={@flow.workspace}
          choose={chooser_path(@flow, @step, card)}
        />
        <li
          :for={adapter <- @waiting}
          id={"set-up-adapter-#{adapter.public_id}"}
          class="flex items-center gap-3 rounded-box border border-line bg-base-100 px-4 py-3"
        >
          <IntegrationComponents.mark class="size-5" />
          <p class="min-w-0 flex-1 truncate font-medium">{Adapters.title(adapter)}</p>
          <span
            id={"set-up-adapter-#{adapter.public_id}-connected"}
            class="q-sdot q-sdot-completed text-[13px]/5"
          >
            <i aria-hidden="true"></i><span>{gettext("Connected")}</span>
          </span>
        </li>
      </ul>

      <details
        :if={@unconnected != []}
        id="set-up-connect"
        class="grid gap-3"
        open={@cards == [] and @waiting == []}
      >
        <summary id="set-up-connect-another" class="btn btn-sm w-fit">
          <span :if={@step == :sources}>{gettext("Connect another source")}</span>
          <span :if={@step == :destinations}>{gettext("Connect another destination")}</span>
        </summary>
        <ul id="set-up-adapters" class="mt-3 grid gap-3">
          <li
            :for={adapter <- @unconnected}
            id={"set-up-adapter-#{adapter.public_id}"}
            class="flex items-center gap-3 rounded-box border border-line bg-base-100 px-4 py-3"
          >
            <IntegrationComponents.mark class="size-5" />
            <p class="min-w-0 flex-1 truncate font-medium">{Adapters.title(adapter)}</p>
            <span
              :if={MapSet.member?(@connecting, adapter.id)}
              id={"set-up-adapter-#{adapter.public_id}-connecting"}
              role="status"
              class="q-sdot q-sdot-pending text-[13px]/5"
            >
              <i aria-hidden="true"></i><span>{gettext("Connecting…")}</span>
            </span>
            <span
              :if={not MapSet.member?(@connecting, adapter.id)}
              id={"set-up-adapter-#{adapter.public_id}-not-connected"}
              class="q-sdot text-[13px]/5 text-muted"
            >
              <i aria-hidden="true"></i><span>{gettext("Not connected")}</span>
            </span>
            <IntegrationComponents.install_form
              :if={@may_connect}
              id={"set-up-adapter-#{adapter.public_id}-connect"}
              adapter={adapter}
              action={IntegrationComponents.paths(@current_scope, adapter).install <> "?" <> URI.encode_query(back: @back)}
              ready={adapter.id in @ready}
              sending={@sending == adapter.public_id}
              label={gettext("Connect")}
            />
          </li>
        </ul>
      </details>

      <p
        :if={!@may and @cards != []}
        id="set-up-who-may"
        class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
      >
        {@who_may}
      </p>

      <p
        :if={@adapters == [] and @step == :sources}
        id="set-up-no-adapter"
        class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
      >
        {gettext(
          "No work source for this type is set up on this instance. An instance admin sets one up in Instance settings › Adapters."
        )}
      </p>

      <p
        :if={@adapters == [] and @step == :destinations}
        id="set-up-no-adapter"
        class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
      >
        {gettext(
          "No work destination for this type is set up on this instance. An instance admin sets one up in Instance settings › Adapters."
        )}
      </p>

      <p
        :if={!@may_connect}
        id="set-up-connect-who-may"
        class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
      >
        {@who_connects}
      </p>

      <p id="set-up-later" class="text-[13px]/5 text-muted">
        <span :if={@step == :sources}>
          {gettext("You can change this later in Workspace settings › Work sources.")}
        </span>
        <span :if={@step == :destinations}>
          {gettext("You can change this later in Workspace settings › Destinations.")}
        </span>
      </p>

      <.acts steps={@steps} page_path={@page_path} next_path={@next_path} skip={!@done} />

      <:context :if={@step == :sources or guides(@unconnected, @ready) != []}>
        <p :if={@step == :sources} id="set-up-what">
          {pgettext("plain", "Bring tickets in from a system this instance has set up.")}
        </p>
        <p :for={adapter <- @unconnected} :if={adapter.id in @ready}>
          {gettext(
            "Connect opens %{adapter} in this tab, and %{adapter} sends you back to Qory Apiary after its steps.",
            adapter: Adapters.title(adapter)
          )}
        </p>
        <SetUpComponents.outside
          :for={{adapter, guide} <- guides(@unconnected, @ready)}
          id={"set-up-help-#{adapter.public_id}"}
          title={gettext("On %{adapter}", adapter: Adapters.title(adapter))}
          guide={guide}
        />
      </:context>
    </SetUpComponents.frame>
    """
  end

  defp flow_step(%{step: :model} = assigns) do
    ~H"""
    <SetUpComponents.frame steps={@steps} title={@title} page={@page_path}>
      <SetUpComponents.heading>{@page_title}</SetUpComponents.heading>

      <.form
        :if={@may}
        for={@form}
        id="set-up-model-form"
        method="post"
        phx-change="choose_model"
        phx-submit="save_model"
        class="grid gap-4"
        novalidate
      >
        <.key_choice
          field={@form[:source]}
          options={source_options(@providers, @may_add)}
          shared={@shared_keys}
          organisation={@current_scope.organisation.name}
        />
        <div :if={@source == :add} id="set-up-model-add" class="grid gap-4 ps-6">
          <.input
            field={@form[:provider]}
            type="choice"
            label={gettext("Provider")}
            options={ProviderPage.provider_options()}
          />
          <.input
            field={@form[:key]}
            id={"set-up-model-key-#{@attempt}"}
            type="password"
            value={nil}
            label={gettext("Key")}
            hint={
              gettext(
                "Qory Apiary stores the key encrypted, and nobody can view it again. You can replace it in Settings › Secrets and variables."
              )
            }
            autocomplete="off"
            spellcheck="false"
            phx-update="ignore"
            required
          />
          <.input
            :for={name <- (@chosen && Provider.address_settings(@chosen)) || []}
            field={@form[String.to_atom(name)]}
            id={"set-up-model-#{name}"}
            type="text"
            inputmode="url"
            label={ProviderPage.setting_title(@chosen, name)}
            placeholder="https://litellm.example.com"
            hint={gettext("The proxy's https address without /v1.")}
            autocomplete="off"
            spellcheck="false"
            required
          />
          <.input
            :if={Apiary.Edition.scope_setting?(@current_scope)}
            field={@form[:everywhere]}
            id="set-up-model-everywhere"
            type="checkbox"
            label={
              gettext("Available to every workspace in %{organisation}",
                organisation: @current_scope.organisation.name
              )
            }
          />
        </div>
        <div :if={length(@runtimes) == 1} id="set-up-model-runtime" class="grid gap-1">
          <p class="text-[13.5px]/5 font-medium">{gettext("Runtime")}</p>
          <p class="text-[13.5px]/5">{hd(@runtimes).title}</p>
          <input type="hidden" name="model[runtime]" value={hd(@runtimes).name} />
        </div>
        <.input
          :if={length(@runtimes) > 1}
          field={@form[:runtime]}
          type="select"
          label={gettext("Runtime")}
          options={for runtime <- @runtimes, do: {runtime.title, runtime.name}}
        />
        <.input
          field={@form[:model]}
          type="select"
          label={gettext("Default model")}
          options={for model <- @models, do: {model.title || model.id, model.id}}
        />
        <p id="set-up-model-later" class="text-[13px]/5 text-muted">
          {later_line(@source, @everywhere, @organisation_secrets)}
        </p>
        <div class="q-su-acts">
          <SetUpComponents.back steps={@steps} page={@page_path} />
          <.button
            id="set-up-continue"
            type="submit"
            variant="primary"
            size="md"
            loading_text={gettext("Saving")}
          >
            {gettext("Continue")}
          </.button>
        </div>
      </.form>

      <p
        :if={!@may}
        id="set-up-who-may"
        class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
      >
        {@who_may}
      </p>
      <.acts :if={!@may} steps={@steps} page_path={@page_path} next_path={@next_path} skip={!@done} />

      <:context>
        <p id="set-up-what">
          {gettext("A model provider's key lets runs in %{workspace} call a model.",
            workspace: @flow.workspace.name
          )}
        </p>
        <ProviderPage.get_key :if={@may and @source == :add} id="set-up-get-key" chosen={@chosen} />
      </:context>
    </SetUpComponents.frame>
    """
  end

  defp flow_step(%{step: :name} = assigns) do
    ~H"""
    <SetUpComponents.frame steps={@steps} title={@title} page={@page_path}>
      <SetUpComponents.heading>{@page_title}</SetUpComponents.heading>

      <.notice :if={@refusal == :limit} kind={:error}>
        <span id="set-up-limit">
          {gettext("%{organisation} may have no more workspaces.",
            organisation: @flow.organisation.name
          )}
        </span>
      </.notice>
      <.notice :if={@refusal == :name_taken} kind={:error}>
        <span id="set-up-name-taken">
          {gettext(
            "Restore %{workspace} in Organisation settings › Workspaces. A deleted workspace keeps its name until it is purged.",
            workspace: String.trim(@form[:name].value || "")
          )}
        </span>
      </.notice>

      <.form
        :if={!@flow.workspace}
        for={@form}
        id="set-up-form"
        phx-submit="create"
        class="grid gap-4"
        novalidate
      >
        <.input field={@form[:name]} type="text" label={gettext("Name")} autocomplete="off" required />
        <p id="set-up-type" class="text-[13px]/5 text-muted">
          {gettext("%{type} · %{organisation}",
            type: @flow.domain.type_name(),
            organisation: @flow.organisation.name
          )}
        </p>
        <div class="q-su-acts">
          <SetUpComponents.back steps={@steps} page={@page_path} />
          <.button variant="primary" size="md" loading_text={gettext("Creating")}>
            {gettext("Create workspace")}
          </.button>
        </div>
      </.form>

      <div :if={@flow.workspace} id="set-up-made" class="grid gap-4">
        <div class="grid gap-1">
          <p class="text-[13.5px]/5 font-medium">{gettext("Name")}</p>
          <p id="set-up-name" class="text-[13.5px]/5">{@flow.workspace.name}</p>
        </div>
        <p id="set-up-type" class="text-[13px]/5 text-muted">
          {gettext("%{type} · %{organisation}",
            type: @flow.domain.type_name(),
            organisation: @flow.organisation.name
          )}
        </p>
        <.acts steps={@steps} page_path={@page_path} next_path={@next_path} skip={false} />
      </div>
    </SetUpComponents.frame>
    """
  end

  defp flow_step(%{step: :test} = assigns) do
    assigns =
      assign(assigns,
        failed?: match?({:failed, _cause}, assigns.test_state),
        workspace: assigns.flow.workspace,
        organisation: assigns.flow.organisation
      )

    ~H"""
    <SetUpComponents.frame steps={@steps} title={@title} page={@page_path}>
      <SetUpComponents.heading>{@page_title}</SetUpComponents.heading>

      <p :if={!@may} id="set-up-who-may" class="text-[13.5px]/5 text-muted">{@who_may}</p>

      <p
        :if={@may and is_nil(@machines) and @test_state not in [:passed, :waiting, :running]}
        id="set-up-test-machines"
        class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
      >
        <.rich text={
          rich_gettext("Runs need a ready pool. %{see}.",
            see: {:link, SetUpComponents.flow_path(@flow, :machines), gettext("See Machines")}
          )
        } />
      </p>

      <.form
        :if={@may and @machines != nil and (is_nil(@test_state) or @failed?)}
        for={@test_form}
        id="set-up-test-form"
        phx-submit="run_test"
        novalidate
        class="grid gap-4"
      >
        <.input
          field={@test_form[:line]}
          label={gettext("Say hi to your agent")}
          maxlength="1024"
          debounce="blur"
        />
        <div class="q-su-acts">
          <SetUpComponents.back steps={@steps} page={@page_path} />
          <.button id="set-up-test-run" type="submit" variant="primary" size="md">
            {gettext("Run the test")}
          </.button>
        </div>
      </.form>

      <p :if={@test_state == :waiting} id="set-up-test-state" role="status" class="text-[13.5px]/5">
        {gettext("The test run is queued for a machine.")}
      </p>
      <p :if={@test_state == :running} id="set-up-test-state" role="status" class="text-[13.5px]/5">
        {gettext("The test run is running.")}
      </p>
      <.link
        :if={@test_state in [:waiting, :running] and @test.run}
        id="set-up-test-run-link"
        navigate={~p"/#{@organisation}/#{@workspace}/runs/#{@test.run.public_id}"}
        class="q-link text-[13.5px]/5"
      >
        {gettext("See the run")}
      </.link>

      <p :if={@test_notice == :test_running} id="set-up-test-running" class="text-[13px]/5 text-muted">
        <.rich text={
          rich_gettext(
            "Wait until the test run in progress ends, then press %{run} again.",
            run: {:b, gettext("Run the test")}
          )
        } />
      </p>

      <.notice :if={@test_state == :passed} kind={:success}>
        <span id="set-up-test-passed">
          {OverviewComponents.passed_line(@test.run)}
          <.link
            navigate={~p"/#{@organisation}/#{@workspace}/runs/#{@test.run.public_id}"}
            class="q-link"
          >
            {gettext("See the run")}
          </.link>
        </span>
      </.notice>
      <.notice :if={@failed?} kind={:error}>
        <span id="set-up-test-failed" data-cause={elem(@test_state, 1)}>
          {OverviewComponents.failed_line(elem(@test_state, 1), @test.run)}
          <.link
            :if={elem(@test_state, 1) == :other and @test.run}
            navigate={~p"/#{@organisation}/#{@workspace}/runs/#{@test.run.public_id}"}
            class="q-link"
          >
            {gettext("See the run")}
          </.link>
        </span>
      </.notice>

      <div :if={!(@may and @machines != nil and (is_nil(@test_state) or @failed?))} class="q-su-acts">
        <SetUpComponents.back steps={@steps} page={@page_path} />
        <.button
          :if={@test_state == :passed}
          id="set-up-go"
          variant="primary"
          size="md"
          navigate={~p"/#{@organisation}/#{@workspace}"}
        >
          {gettext("Go to %{workspace}", workspace: @workspace.name)}
        </.button>
      </div>
    </SetUpComponents.frame>
    """
  end

  defp flow_step(%{step: :harness} = assigns) do
    assigns =
      assign(assigns,
        choice: harness_choice(assigns.form.params, assigns.linked, assigns.shared_harness)
      )

    ~H"""
    <SetUpComponents.frame steps={@steps} title={@title} page={@page_path}>
      <SetUpComponents.heading>{@page_title}</SetUpComponents.heading>

      <div class="grid gap-4">
        <.form
          for={@form}
          id="set-up-harness-form"
          phx-change="choose_harness"
          phx-submit="save_harness"
          class="grid gap-4"
          novalidate
        >
          <HarnessComponents.choices
            form={@form}
            chosen={@chosen}
            qory={@qory}
            linked={@linked}
            complete={@linked_complete}
            organisation={@flow.organisation.name}
            disabled={!@may or @saving}
            file_first={@harness_file}
            shared={@shared_harness}
          />

          <.input
            :if={Apiary.Edition.scope_setting?(@current_scope)}
            field={@form[:everywhere]}
            id="set-up-harness-everywhere"
            type="checkbox"
            label={
              gettext("Available to every workspace in %{organisation}",
                organisation: @flow.organisation.name
              )
            }
            disabled={!@may or @saving}
          />

          <.notice :if={@harness_refusal} kind={:error}>
            <span id="set-up-harness-refusal" data-reason={harness_refusal_code(@harness_refusal)}>
              {elem(@harness_refusal, 1)}
            </span>
          </.notice>
        </.form>

        <HarnessComponents.targets
          targets={@harness_targets}
          may={@may}
          edit={@target_edit}
          qory={@target_qory}
          linked={@linked}
          complete={@linked_complete}
          assigned={@harness_assigned}
          organisation={@flow.organisation.name}
        />

        <p
          :if={!@may}
          id="set-up-who-may"
          class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
        >
          {@who_may}
        </p>

        <p id="set-up-later" class="text-[13px]/5 text-muted">
          {gettext("You can change this later in Workspace settings › Workflow.")}
        </p>

        <%!-- Continue is below the destinations' forms, which may not nest in the harness
        form; its `form` submits the harness form. --%>
        <div :if={@may} class="q-su-acts">
          <SetUpComponents.back steps={@steps} page={@page_path} />
          <.button
            id="set-up-continue"
            type="submit"
            form="set-up-harness-form"
            variant="primary"
            size="md"
            disabled={is_nil(@choice) or @saving}
            loading_text={gettext("Saving")}
          >
            {if @saving, do: gettext("Saving"), else: gettext("Continue")}
          </.button>
        </div>
      </div>

      <.acts :if={!@may} steps={@steps} page_path={@page_path} next_path={@next_path} skip={!@done} />
    </SetUpComponents.frame>
    """
  end

  defp flow_step(%{step: :machines} = assigns) do
    %{pools: pools, instance_admin: admin?, enrols: enrols} = assigns

    choosing = assigns.makes_pool and assigns.workspace_pools == []
    removable = assigns.pool_removable
    shared = if(choosing, do: hd(pools), else: assigns.shared_line)

    assigns =
      assign(assigns,
        only: assigns.shared_line == nil and match?([_line], pools),
        lines:
          for(
            line <- pools,
            do:
              {pool_line_id(line), line, pool_act(line, admin?, enrols),
               pool_way(line, assigns.pool_codes)}
          ),
        choosing: choosing,
        shared: shared && {pool_line_id(shared), shared, pool_act(shared, admin?, enrols)},
        chosen:
          cond do
            choosing -> assigns.pool_choice
            assigns.pool_removing -> "shared"
            true -> "workspace"
          end,
        enrolled: removable != nil and enrolled?(hd(pools)),
        shared_off: not choosing and removable == nil
      )

    ~H"""
    <SetUpComponents.frame steps={@steps} title={@title} page={@page_path}>
      <SetUpComponents.heading>{@page_title}</SetUpComponents.heading>

      <%!-- While the workspace has no pool, a person who may make one chooses: the
           instance's pool, its line as below, or a pool for the workspace. Once the
           workspace has its one pool, a person who may remove it chooses the same way:
           Shared opens the confirmation of the removal on the Shared row. --%>
      <form
        :if={@choosing or @shared_line}
        id="set-up-pool-choice"
        phx-change="choose_pool"
        novalidate
        class="grid gap-4"
      >
        <fieldset id="set-up-pool-choices" class="q-choices grid gap-2">
          <label
            :for={{id, line, act} <- [@shared]}
            id={id}
            for={"#{id}-radio"}
            class="q-choice"
          >
            <input
              type="radio"
              id={"#{id}-radio"}
              name="pool[choice]"
              value="shared"
              checked={@chosen == "shared"}
              disabled={@shared_off}
              class="radio radio-sm radio-primary"
            />
            <span id={"#{id}-name"} class="q-choice-h">{gettext("Shared: the instance's pool")}</span>
            <span id={"#{id}-state"} class="q-choice-p">
              <span class={["q-sdot", ready?(line) && "q-sdot-completed"]}>
                <i aria-hidden="true"></i><span>{pool_state_line(line.state)}</span>
              </span>
            </span>
            <span :if={act == :check} class="q-choice-p">
              <.link id={"#{id}-check"} navigate={~p"/instance/nodes"} class="q-link">
                {gettext("Check the nodes")}
              </.link>
            </span>
            <span :if={act == :instance} id={"#{id}-who-may"} class="q-choice-p">
              {@who_may[act]}
            </span>
            <span :if={@pool_removing} id="set-up-pool-remove" class="q-choice-p grid gap-2">
              <span id="set-up-pool-remove-line" class="text-base-content">
                {gettext(
                  "Remove the pool %{pool}? Runs in %{workspace} then use the instance's pool.",
                  pool: @pool_removable.name,
                  workspace: @flow.workspace.name
                )}
              </span>
              <span :if={@enrolled} id="set-up-pool-remove-enrolled">
                {gettext(
                  "The machines in %{pool} stop taking runs, because the pool's access key is revoked.",
                  pool: @pool_removable.name
                )}
              </span>
              <span class="flex flex-wrap gap-2">
                <.button
                  id="set-up-pool-remove-button"
                  type="button"
                  variant="danger"
                  phx-click="remove_pool"
                >
                  {gettext("Remove pool")}
                </.button>
                <.button id="set-up-pool-remove-cancel" type="button" phx-click="keep_pool">
                  {gettext("Cancel")}
                </.button>
              </span>
            </span>
          </label>
          <label id="set-up-pool-workspace" for="set-up-pool-workspace-radio" class="q-choice">
            <input
              type="radio"
              id="set-up-pool-workspace-radio"
              name="pool[choice]"
              value="workspace"
              checked={@chosen == "workspace"}
              class="radio radio-sm radio-primary"
            />
            <span id="set-up-pool-workspace-name" class="q-choice-h">
              {gettext("A pool for %{workspace}", workspace: @flow.workspace.name)}
            </span>
            <span id="set-up-pool-workspace-line" class="q-choice-p">
              {gettext(
                "Runs in %{workspace} then wait for this pool, and the shared pool stops serving them.",
                workspace: @flow.workspace.name
              )}
            </span>
          </label>
        </fieldset>
      </form>

      <div :if={@choosing and @pool_choice == "workspace"} id="set-up-pool-add" class="grid gap-2">
        <div>
          <.button id="set-up-pool-add-button" phx-click="add_pool" size="md">
            {gettext("Add node pool")}
          </.button>
        </div>
        <p :if={@pool_taken} id="set-up-pool-taken" class="text-[13px]/5 text-error">
          {pool_taken_line(@pool_taken, @flow.workspace)}
        </p>
      </div>

      <ul :if={!@choosing} id="set-up-pools" class="q-choices grid gap-2">
        <li :for={{id, line, act, way} <- @lines} id={id} class="q-choice cursor-default">
          <input
            :if={@only}
            type="radio"
            id={"#{id}-radio"}
            checked
            disabled
            aria-labelledby={"#{id}-name"}
            class="radio radio-sm radio-primary"
          />
          <span :if={!@only} aria-hidden="true"></span>
          <span id={"#{id}-name"} class="q-choice-h">
            <span :if={line.instance}>{gettext("The instance's pool")}</span>
            <span :if={!line.instance and act != :pool}>{line.pool.name}</span>
            <.link
              :if={act == :pool}
              navigate={~p"/#{@flow.organisation}/#{@flow.workspace}/nodes/#{line.pool}"}
              class="q-link"
            >
              {line.pool.name}
            </.link>
          </span>
          <span id={"#{id}-state"} class="q-choice-p">
            <span class={["q-sdot", ready?(line) && "q-sdot-completed"]}>
              <i aria-hidden="true"></i><span>{pool_state_line(line.state)}</span>
            </span>
          </span>
          <span :if={act == :check} class="q-choice-p">
            <.link id={"#{id}-check"} navigate={~p"/instance/nodes"} class="q-link">
              {gettext("Check the nodes")}
            </.link>
          </span>
          <span :if={act in [:instance, :workspace]} id={"#{id}-who-may"} class="q-choice-p">
            {@who_may[act]}
          </span>
          <span :if={way} class="q-choice-p">
            <.button
              id={"#{id}-code"}
              phx-click="pool_code"
              phx-value-pool={line.pool.public_id}
              size="sm"
            >
              {way}
            </.button>
          </span>
          <div
            :if={issued_for?(@pool_issued, line)}
            id={"#{id}-command"}
            class="q-choice-p grid gap-1.5"
          >
            <p id={"#{id}-command-run"} class="text-[13px]/5">
              {gettext("On the machine for the pool %{pool}, run:", pool: line.pool.name)}
            </p>
            <.command_line
              id={"#{id}-command-line"}
              command={
                ApiaryWeb.NodeComponents.enrol_command(ApiaryWeb.Endpoint.url(), @pool_issued.code.(),
                  replace: @pool_issued.replace,
                  via: @pool_issued.through && @pool_issued.through.url
                )
              }
            />
            <ApiaryWeb.NodeComponents.via_ca_line
              id={"#{id}-command-via-ca"}
              gateway={@pool_issued.through}
            />
            <p id={"#{id}-command-where"} class="text-[13px]/5">
              {gettext(
                "Run this on the Linux machine with Docker that runs the runs in %{workspace}. It joins that machine to the pool %{pool}. Install qory there first:",
                workspace: @flow.workspace.name,
                pool: line.pool.name
              )}
            </p>
            <.command_line
              id={"#{id}-command-install"}
              command="curl -fsSL https://raw.githubusercontent.com/qoryai/qory/main/install.sh | sh"
            />
          </div>
        </li>
      </ul>

      <.acts steps={@steps} page_path={@page_path} next_path={@next_path} skip={!@done} />
    </SetUpComponents.frame>
    """
  end

  # Who acts on a pool's line: nil for a ready pool; for the instance's pool, `:check`,
  # Check the nodes, for an instance admin, else `:instance`, who acts; for a pool of the
  # workspace, `:pool`, the link to its page, for a person who may enrol it, else
  # `:workspace`, who acts.
  defp pool_act(%{state: {:ready, _gateway}}, _admin?, _enrols), do: nil
  defp pool_act(%{instance: true}, true, _enrols), do: :check
  defp pool_act(%{instance: true}, false, _enrols), do: :instance

  defp pool_act(%{pool: pool}, _admin?, enrols),
    do: if(MapSet.member?(enrols, pool.id), do: :pool, else: :workspace)

  defp pool_line_id(%{instance: true}), do: "set-up-pool-instance"
  defp pool_line_id(%{pool: pool}), do: "set-up-pool-#{pool.public_id}"

  defp ready?(%{state: state}), do: match?({:ready, _gateway}, state)

  # Whether a machine enrolled on the pool of `line`: whether the pool has an active key
  # (`Apiary.AccessKeys.active_key?/1`), the first rule of its state.
  defp enrolled?(%{state: state}), do: state != {:not_ready, :no_active_key}

  # Whether the step keeps the choice of Shared or the workspace's pool once the workspace
  # has a pool: for its only pool, and a person whom `node.delete` allows on it. Where the
  # workspace has 2 pools or more, the step keeps no choice, since any of them stops the
  # instance's pool serving the workspace.
  defp keeps_choice?(scope, [pool]), do: Access.can?(scope, :"node.delete", pool)
  defp keeps_choice?(_scope, _pools), do: false

  # The pool of the workspace that the step offers to remove, to choose Shared again: the
  # workspace's only pool, where the step keeps the choice and the instance has a pool
  # (`shared_line`); else nil.
  defp removable_pool([pool], %{pool: %{}}), do: pool
  defp removable_pool(_pools, _shared_line), do: nil

  # The words of Get the command on a pool's line, as the pool's Access key tab words it,
  # for a pool of the workspace whose command the person may get while it has room for a
  # key; else nil, and no button.
  defp pool_way(%{instance: false, pool: %{id: id}}, pool_codes) do
    case pool_codes do
      %{^id => %{codes: codes, keys: keys}} ->
        cond do
          pool_at_limit?(keys) -> nil
          codes == [] -> gettext("Get the command")
          true -> gettext("Get a new command")
        end

      _none ->
        nil
    end
  end

  defp pool_way(_instance_line, _pool_codes), do: nil

  # The page listens to each pool of the workspace once, while it is connected: a read
  # again of the step subscribes to no pool twice.
  defp listen_to_pools(socket, workspace_pools) do
    listened = socket.assigns[:pool_listened] || MapSet.new()
    scope = socket.assigns.current_scope

    listened =
      for pool <- workspace_pools,
          connected?(socket),
          pool.id not in listened,
          reduce: listened do
        acc ->
          _subscribed = Apiary.AccessKeys.subscribe(scope, pool)
          MapSet.put(acc, pool.id)
      end

    assign(socket, :pool_listened, listened)
  end

  # One read again of the step as the first outstanding code of the pools expires, so the
  # command and Get a new command go with it. Each read cancels the timer it replaces.
  defp schedule_pool_expiry(socket, pool_codes) do
    if timer = socket.assigns[:pool_timer], do: Process.cancel_timer(timer)
    now = DateTime.utc_now()
    times = for {_id, %{codes: codes}} <- pool_codes, code <- codes, do: code.expires_at

    timer =
      if connected?(socket) and times != [] do
        wait = DateTime.diff(Enum.min(times, DateTime), now, :millisecond)
        Process.send_after(self(), :pool_codes_expire, max(wait, 0) + 1)
      end

    assign(socket, :pool_timer, timer)
  end

  # Whether the command got is of the pool on `line`.
  defp issued_for?(%{pool_id: id}, %{instance: false, pool: %{id: id}}), do: true
  defp issued_for?(_issued, _line), do: false

  # Get the command's code for `pool`. The code as the machine sends it is kept in a
  # function, as the pool's Access key tab keeps it: shown under the pool's line, and
  # printed by nothing else. `replace` is for a pool that has or had a key; `through` is
  # the gateway the pool's choice leads to, or nil.
  defp pool_code(socket, scope, pool) do
    case Apiary.AccessKeys.create_enrolment_code(scope, pool, %{}) do
      {:ok, row, code} ->
        code = Apiary.Contract.Enrolment.issued_code(code, Apiary.SigningKey.fingerprint())

        issued = %{
          pool_id: pool.id,
          row: row,
          code: fn -> code end,
          replace: socket.assigns.pool_codes[pool.id].keys != [],
          through: Apiary.Gateways.chosen(pool)
        }

        {:noreply, socket |> assign(pool_issued: issued) |> reload()}

      {:error, :forbidden} ->
        why = gettext("Only owners and admins connect a node.")

        {:noreply,
         socket
         |> put_flash(:error, ApiaryWeb.Access.who_may(scope, :"access_key.create_code", why))
         |> reload()}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket |> put_flash(:error, gettext("Nothing was changed. Try again.")) |> reload()}

      # The pool deleted, or out of reach: the step as it is now.
      {:error, _reason} ->
        {:noreply, reload(socket)}
    end
  end

  # Whether a pool has as many active keys as a node may have (`Apiary.AccessKeys.key_limit/0`):
  # then no code is made, as on the pool's Access key tab.
  defp pool_at_limit?(keys),
    do: Enum.count(keys, &is_nil(&1.revoked_at)) >= Apiary.AccessKeys.key_limit()

  # Whether Add node pool was refused for the name: another node of the workspace in use
  # has it (`nodes_live_name_index`).
  defp pool_name_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:name, {_message, opts}} ->
        opts[:constraint] == :unique and opts[:constraint_name] == "nodes_live_name_index"

      _other ->
        false
    end)
  end

  # The line under Add node pool where another node of the workspace has the pool's name.
  defp pool_taken_line(name, workspace),
    do:
      gettext(
        "Rename the node %{name} on the Nodes page, then add the pool. A node of %{workspace} already has that name.",
        name: name,
        workspace: workspace.name
      )

  # The state of a pool's line on the Machines step.
  defp pool_state_line({:ready, gateway}),
    do: gettext("Ready · gateway: %{gateway}", gateway: gateway.name)

  defp pool_state_line({:not_ready, :no_pool}), do: gettext("Not ready: no pool")
  defp pool_state_line({:not_ready, :no_active_key}), do: gettext("Not ready: no active key")

  defp pool_state_line({:not_ready, :direct}),
    do: gettext("Not ready: the pool is set to Direct, and runs need a gateway")

  defp pool_state_line({:not_ready, :no_gateway}), do: gettext("Not ready: no gateway")

  defp pool_state_line({:not_ready, :gateway_not_serving}),
    do: gettext("Not ready: the pool's runs may not go through the chosen gateway")

  defp pool_state_line({:not_ready, :gateway_without_key}),
    do: gettext("Not ready: the gateway has no active key")

  # The failure code of a refused save, for the page's tests: the walk's, or `limited`.
  defp harness_refusal_code({{:walk, %{failure: failure}}, _words}), do: failure
  defp harness_refusal_code({{:limited, _seconds}, _words}), do: "limited"
  defp harness_refusal_code({:shared, _words}), do: "shared"
  defp harness_refusal_code(_refusal), do: nil

  attr :steps, :list, required: true
  attr :page_path, :string, required: true
  attr :next_path, :string, default: nil
  attr :skip, :boolean, required: true

  # Back, and Skip while the step is not done, else Continue, to the next step.
  defp acts(assigns) do
    ~H"""
    <div class="q-su-acts">
      <SetUpComponents.back steps={@steps} page={@page_path} />
      <.button
        :if={@next_path && @skip}
        id="set-up-skip"
        variant="ghost"
        size="md"
        patch={patch?(@next_path, @page_path) && @next_path}
        navigate={!patch?(@next_path, @page_path) && @next_path}
      >
        {gettext("Skip")}
      </.button>
      <.button
        :if={@next_path && !@skip}
        id="set-up-continue"
        variant="primary"
        size="md"
        patch={patch?(@next_path, @page_path) && @next_path}
        navigate={!patch?(@next_path, @page_path) && @next_path}
      >
        {gettext("Continue")}
      </.button>
    </div>
    """
  end

  defp patch?(path, page), do: URI.parse(path).path == page

  # Each adapter whose Connect can be pressed, among the ids `ready`, and whose guide has
  # steps for connecting it, with them.
  defp guides(adapters, ready) do
    for adapter <- adapters,
        adapter.id in ready,
        guide = Adapters.guide(adapter, :connect),
        do: {adapter, guide}
  end

  # The chooser of `card`'s grant for the step `step` of `flow`'s workspace.
  defp chooser_path(%{organisation: organisation, workspace: workspace}, step, card),
    do:
      ~p"/#{organisation}/set-up/choose?#{[step: step, grant: card.grant.public_id, workspace: workspace.slug]}"
end
