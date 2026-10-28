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
  # The steps of a workspace that exists take `&workspace=<slug>`, its slug, which the
  # scope resolves as it does a workspace's pages; without it, the workspace the scope
  # has. Before the workspace exists, `&type=<name>` is the type picked; a flow with no
  # type shows the cards. `/:org/set-up` sets up a new workspace while the organisation
  # has none in use, else the scope's workspace; `/:org/workspaces/new` a new workspace
  # until Name creates it, then the steps go on at `/:org/set-up`. Once every step of a
  # workspace is done, `/:org/set-up` without a step sends the person to the workspace's
  # first page. The steps, each as `Apiary.WorkspaceSetup.done?/3` counts it:
  #
  #   * Work sources and Work destinations, for the organisation, with the `factory`
  #     feature: the instance's configured adapters that serve the type
  #     (`Apiary.Adapters.list_configured/1`), those with items for Work sources and those
  #     with `targets` true for Work destinations, each Connected while the organisation's
  #     connection to it is connected, Connecting… while it is pending, else Not
  #     connected, with Connect, the Install of Organisation settings › Integrations
  #     (`ApiaryWeb.IntegrationComponents.install_form/1`), whose return leads back to the
  #     step (`ApiaryWeb.ConnectSession.back?/1`). In the context column, for each adapter
  #     whose Connect can be pressed and whose guide has steps for connecting it
  #     (`Apiary.Adapters.guide/2`), those steps. Skip while the step is not done, else
  #     Continue. A person whom `adapter.connect` does not allow sees the adapters with no
  #     Connect, and
  #     who may connect (`ApiaryWeb.Access.who_may/3`). The page listens to the
  #     organisation's collections and connections (`Apiary.Adapters.Collections.subscribe/1`)
  #     and reads the step again on each change;
  #   * Model, for the organisation, with the features `factory` and `secrets`: Provider,
  #     Key and, for a provider that needs one, Address, which add a model provider as
  #     Organisation settings › Model providers does (`Apiary.Connections.create_provider/2`),
  #     while the organisation has no provider with a key; else the line that it has one.
  #     Then Runtime, the runtimes the provider serves (`Apiary.Kinds.Providers.serve/2`),
  #     as text where there is one, and Default model, the models suggested for the
  #     provider and runtime (`Apiary.ModelChoices.suggestions/2`). Continue saves the
  #     organisation's default (level 6, `Apiary.ModelChoices.put_choice/4`). The key is
  #     never kept in an assign: its field is left out of the page's patches
  #     (`phx-update="ignore"`). A person whom `provider.write` does not allow sees who may;
  #   * Name, for the workspace: the Name field, "Main" for the organisation's first
  #     workspace, and Create workspace, with the type picked: on `/:org/set-up`, the
  #     organisation's first workspace (`Apiary.Organisations.create_first_workspace/2`,
  #     which returns `{:error, :exists}` for a second, under the organisation's lock), on
  #     `/:org/workspaces/new`
  #     any other (`Apiary.Organisations.create_workspace/2`); once the workspace exists,
  #     its name, read only, with Continue;
  #   * Work sources used and Destinations used, with the `factory` feature: tick lists of
  #     the organisation's collections (`ApiaryWeb.TickListComponents`), which Workspace
  #     settings › Work sources and › Destinations show too. A tick
  #     (`Apiary.WorkspaceSetup.tick/5`) reads the list again first, and changes nothing
  #     for a collection that is now in another workspace. A person whom
  #     `collection.assign` does not allow sees the boxes disabled, and who may;
  #   * Harness, with the `factory` feature: the three harness choices
  #     (`ApiaryWeb.HarnessComponents.choices/1`), the saved one chosen, else the Qory
  #     harness. The linked repositories of a harness repository are read once the step
  #     opens, outside the page's process, once per page. Continue saves the choice
  #     (`Apiary.Stacks.Sources.choose/2`) and goes on, or goes on where it is the saved
  #     one; a harness repository is read outside the page's process while Continue shows
  #     Saving, and a read that failed says why. A person whom `harness.save` does not
  #     allow sees the choices disabled, and who may;
  #   * Machines, with the `factory` feature, read only: the node pools that serve the
  #     workspace's runs, each with its state (`Apiary.WorkspaceSetup.pools/1`): the
  #     workspace's pools, or the instance's pool while it has none. A pool that is the
  #     only one shows chosen. A ready pool shows its gateway's name; a pool that is not
  #     ready shows the reason (`t:Apiary.WorkspaceSetup.not_ready_reason/0`): no pool, no
  #     active key, a choice of Direct, no gateway, a chosen gateway that the pool's runs
  #     may not go through, or a gateway with no active key. Under a pool that is not
  #     ready: for the instance's pool, Check the nodes, to `/instance/nodes`, for an
  #     instance admin; for a pool of the workspace, its name links to its page for a
  #     person whom `access_key.create_code` allows on it. Anyone else reads who acts
  #     (`c:Apiary.Edition.machines_who_may/3`). Nothing on the step writes;
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
  # page: Work sources has none, so Back never leads to the cards or the instance's steps.
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
    SetUpComponents,
    TickListComponents
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
  # done. A step of the workspace before it exists opens Name.
  defp open_flow(socket, flow, step_param) do
    scope = socket.assigns.current_scope
    plain = SetUpComponents.steps_for(scope, nil, flow: flow)
    ids = for %{id: id, group: group} <- plain, group in [:organisation, :workspace], do: id
    named = Enum.find(ids, &(Atom.to_string(&1) == step_param))
    pending = Enum.find(plain, &(&1.id in ids and &1.state != :done))

    current =
      cond do
        is_nil(named) -> pending && pending.id
        flow.workspace != nil -> named
        WorkspaceSetup.flow()[named] == :organisation -> named
        true -> :name
      end

    cond do
      current ->
        assign_step(socket, flow, current)

      flow.workspace ->
        push_navigate(socket, to: Layouts.workspace_landing(scope))

      true ->
        assign_step(socket, flow, List.last(ids))
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

  defp heading(:sources, flow),
    do:
      gettext("Where does %{organisation}'s work come from?",
        organisation: flow.organisation.name
      )

  defp heading(:destinations, flow),
    do: gettext("Where do %{organisation}'s changes go?", organisation: flow.organisation.name)

  defp heading(:model, flow),
    do:
      gettext("Which model do %{organisation}'s runs use?", organisation: flow.organisation.name)

  defp heading(:name, _flow), do: gettext("Name this workspace")

  defp heading(:sources_used, flow),
    do: gettext("Which work sources does %{workspace} use?", workspace: flow.workspace.name)

  defp heading(:destinations_used, flow),
    do:
      gettext("Which targets may runs in %{workspace} change?",
        workspace: flow.workspace.name
      )

  defp heading(:harness, flow),
    do: gettext("Which harness do runs in %{workspace} use?", workspace: flow.workspace.name)

  defp heading(:machines, flow),
    do: gettext("Which machines run the runs in %{workspace}?", workspace: flow.workspace.name)

  defp heading(:test, _flow), do: gettext("Run a test")

  ## Each step's data

  defp load_step(%{assigns: %{step: step}} = socket) when step in [:sources, :destinations] do
    %{current_scope: scope, flow: flow} = socket.assigns
    role = if step == :sources, do: :items, else: :targets

    adapters =
      for adapter <- Adapters.list_configured(flow.domain),
          if(role == :items, do: Adapters.items?(adapter), else: adapter.targets == true),
          do: adapter

    connecting =
      for {adapter_id, %{state: :pending}} <- AdapterConnections.live_by_adapter(scope),
          into: MapSet.new(),
          do: adapter_id

    may = Access.can?(scope, :"adapter.connect", scope.organisation)

    assign(socket,
      adapters: adapters,
      connected: WorkspaceSetup.connected_ids(flow.organisation, flow.domain, role),
      connecting: connecting,
      may: may,
      who_may:
        ApiaryWeb.Access.who_may(
          scope,
          :"adapter.connect",
          gettext("Only owners and admins change the integrations of the organisation.")
        ),
      ready:
        for(
          a <- adapters,
          may,
          IntegrationComponents.ready?(a),
          into: MapSet.new(),
          do: a.id
        ),
      sending: nil,
      done: step_done?(socket.assigns.flow, step)
    )
  end

  defp load_step(%{assigns: %{step: :model}} = socket) do
    scope = socket.assigns.current_scope
    may = Access.can?(scope, :"provider.write", scope.organisation)

    providers =
      case Connections.list_providers(scope) do
        {:ok, providers} -> Enum.filter(providers, &(keys(&1) > 0))
        {:error, _reason} -> []
      end

    default = organisation_default(scope)

    existing =
      Enum.find(providers, &(default && &1.id == default.connection_id)) || List.first(providers)

    socket
    |> assign(
      may: may,
      who_may:
        ApiaryWeb.Access.who_may(
          scope,
          :"provider.write",
          gettext("Only owners and admins add a model key.")
        ),
      existing: existing,
      default: default,
      done: step_done?(socket.assigns.flow, :model)
    )
    |> assign_model_form(model_params(existing, default), [])
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

  defp load_step(%{assigns: %{step: step}} = socket)
       when step in [:sources_used, :destinations_used] do
    %{current_scope: scope, flow: flow, steps: steps} = socket.assigns
    list = tick_list(step)

    assign(
      socket,
      TickListComponents.load(
        scope,
        flow.domain,
        list,
        Enum.find_value(steps, fn step -> step.id == list && step.path end)
      )
    )
  end

  defp load_step(%{assigns: %{step: :harness}} = socket) do
    %{current_scope: scope, flow: %{workspace: workspace}} = socket.assigns
    chosen = Sources.chosen(workspace)
    may = Access.can?(scope, :"harness.save", workspace)

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
      qory: HarnessComponents.qory(chosen, workspace),
      saving: false,
      harness_refusal: nil,
      done: step_done?(socket.assigns.flow, :harness)
    )
    |> assign_harness_form(HarnessComponents.form_params(chosen, socket.assigns.linked))
    |> list_linked()
  end

  # The step reads the pools and writes nothing: each pool's line, who may act on a pool
  # that is not ready, and who acts for anyone else.
  defp load_step(%{assigns: %{step: :machines}} = socket) do
    %{current_scope: scope, flow: %{workspace: workspace}} = socket.assigns
    pools = WorkspaceSetup.pools(workspace)

    assign(socket,
      pools: pools,
      instance_admin: Access.instance_admin?(scope),
      enrols:
        for(
          %{pool: %{workspace_id: id} = pool} <- pools,
          id != nil,
          Access.can?(scope, :"access_key.create_code", pool),
          into: MapSet.new(),
          do: pool.id
        ),
      who_may: %{
        instance: Edition.machines_who_may(scope, workspace, :instance),
        workspace: Edition.machines_who_may(scope, workspace, :workspace)
      },
      done: step_done?(socket.assigns.flow, :machines)
    )
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

  ## The Model step's form

  # The organisation's default (level 6), nil for none.
  defp organisation_default(scope) do
    case ModelChoices.list_choices(scope) do
      {:ok, choices} ->
        Enum.find(
          choices,
          &(is_nil(&1.workspace_id) and is_nil(&1.target_id) and is_nil(&1.workflow))
        )

      {:error, _reason} ->
        nil
    end
  end

  defp model_params(nil, _default),
    do: %{"provider" => Providers.list() |> hd() |> Map.fetch!(:name)}

  defp model_params(_existing, default),
    do: %{"runtime" => default && default.runtime, "model" => default && default.model_id}

  # The form of the Model step, from what was sent but the key, with `errors` on its
  # fields; the key's field is always empty. The provider is the catalogue's for a new
  # provider, the description of the organisation's provider for one it has.
  defp assign_model_form(socket, params, errors) do
    existing = socket.assigns.existing

    chosen =
      case existing do
        nil -> catalogue(params["provider"])
        provider -> described(provider)
      end

    runtimes =
      if chosen, do: Enum.filter(Runtimes.list(), &Providers.serves?(chosen, &1)), else: []

    runtime = Enum.find(runtimes, &(&1.name == params["runtime"])) || List.first(runtimes)

    models =
      cond do
        is_nil(runtime) -> []
        existing -> ModelChoices.suggestions(existing, runtime)
        true -> ModelChoices.suggestions(chosen, runtime)
      end

    model = Enum.find(models, &(&1.id == params["model"])) || List.first(models)

    kept =
      if existing,
        do: %{},
        else: Map.take(params, ["provider" | ProviderPage.address_names(params["provider"])])

    values =
      Map.merge(kept, %{
        "key" => "",
        "runtime" => runtime && runtime.name,
        "model" => model && model.id
      })

    values = Enum.reduce(errors, values, fn {field, _}, v -> Map.put_new(v, "#{field}", "") end)

    assign(socket,
      form: to_form(values, as: :model, errors: errors),
      chosen: chosen,
      runtimes: runtimes,
      runtime: runtime,
      models: models
    )
  end

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

  # Adds the provider with its key, for an organisation that has none with a key; the
  # one it has, else.
  defp model_provider(%{assigns: %{existing: nil, current_scope: scope}}, params) do
    with %Provider{} = provider <- catalogue(params["provider"]) || {:error, :provider_unknown},
         runtime = Enum.find(Runtimes.list(), &(&1.name == params["runtime"])),
         :ok <- if(runtime, do: serves(provider, runtime), else: :ok) do
      Connections.create_provider(scope, %{
        "provider" => provider.name,
        "keys" => [%{"value_id" => "key-1", "value" => params["key"] || ""}],
        "settings" => Map.new(ProviderPage.address_names(provider.name), &{&1, params[&1] || ""})
      })
    end
  end

  defp model_provider(%{assigns: %{existing: provider}}, _params), do: {:ok, provider}

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
        %{assigns: %{step: step, may: true}} = socket
      )
      when step in [:sources, :destinations] do
    if Enum.any?(socket.assigns.adapters, &(&1.public_id == public_id)),
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
    default = socket.assigns.default

    unchanged? =
      case {socket.assigns.existing, default} do
        {%{id: id}, %{connection_id: id, runtime: runtime, model_id: model}} ->
          runtime == params["runtime"] and model == params["model"]

        _other ->
          false
      end

    if unchanged? do
      {:noreply, push_patch(socket, to: socket.assigns.next_path || socket.assigns.page_path)}
    else
      save_model(socket, scope, params)
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

  def handle_event("tick", %{"id" => id}, %{assigns: %{step: step, may: true}} = socket)
      when step in [:sources_used, :destinations_used] do
    %{current_scope: scope, flow: flow} = socket.assigns
    ticked = WorkspaceSetup.tick(scope, flow.workspace, flow.domain, tick_list(step), id)

    {:noreply,
     socket |> TickListComponents.put_tick_flash(ticked, socket.assigns.who_may) |> reload()}
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

    case HarnessComponents.choice(params, linked) do
      nil ->
        {:noreply, socket}

      choice ->
        cond do
          HarnessComponents.unchanged?(choice, chosen) ->
            {:noreply, go_on(socket)}

          match?({:repository, _source, _ref}, choice) ->
            {:noreply,
             socket
             |> assign(saving: true, harness_refusal: nil)
             |> start_async(:harness_save, fn -> {choice, Sources.choose(scope, choice)} end)}

          true ->
            {:noreply, harness_saved(socket, choice, Sources.choose(scope, choice))}
        end
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

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp save_model(socket, scope, params) do
    with {:ok, provider} <- model_provider(socket, params),
         {:ok, _choice} <-
           ModelChoices.put_choice(scope, :organisation, %{
             "provider" => provider.public_id,
             "runtime" => params["runtime"],
             "model" => params["model"]
           }) do
      {:noreply, push_patch(socket, to: socket.assigns.next_path || socket.assigns.page_path)}
    else
      {:error, {:serves, error}} ->
        {:noreply, assign_model_form(socket, params, provider: error)}

      {:error, :provider_unknown} ->
        {:noreply, assign_model_form(socket, params, provider: {"is invalid", []})}

      {:error, %Ecto.Changeset{data: %Apiary.ModelChoices.ModelChoice{}} = changeset} ->
        errors = for {field, error} <- changeset.errors, do: {model_field(field), error}
        {:noreply, socket |> load_step() |> assign_model_form(params, errors)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_model_form(socket, params, ProviderPage.field_errors(changeset))}

      {:error, :forbidden} ->
        {:noreply, socket |> load_step() |> put_flash(:error, socket.assigns.who_may)}

      {:error, _reason} ->
        {:noreply,
         socket |> load_step() |> put_flash(:error, gettext("Nothing was changed. Try again."))}
    end
  end

  defp go_on(socket),
    do: push_patch(socket, to: socket.assigns.next_path || socket.assigns.page_path)

  # The answer to a save of the harness choice `choice`.
  defp harness_saved(socket, _choice, {:ok, _stack}), do: go_on(socket)

  defp harness_saved(socket, _choice, {:error, :forbidden}),
    do: socket |> load_step() |> put_flash(:error, socket.assigns.who_may)

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
  defp model_field(_field), do: :provider

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

  # The tick list of a step: Work sources used's, `:sources`; Destinations used's,
  # `:destinations`.
  defp tick_list(:sources_used), do: :sources
  defp tick_list(:destinations_used), do: :destinations

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
  def handle_async(:harness_linked, {:ok, {:ok, %{sources: linked}}}, socket),
    do: {:noreply, harness_listed(socket, linked)}

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
    assigns =
      assign(assigns,
        back:
          Enum.join(
            [
              if(assigns.flow.page == :new, do: "new-workspace", else: "set-up"),
              step
              | if(assigns.flow.workspace,
                  do: ["workspace=" <> assigns.flow.workspace.slug],
                  else: [assigns.flow.domain.name()]
                )
            ],
            ":"
          )
      )

    ~H"""
    <SetUpComponents.frame steps={@steps} title={@title} page={@page_path}>
      <SetUpComponents.heading>{@page_title}</SetUpComponents.heading>

      <ul :if={@adapters != []} id="set-up-adapters" class="grid gap-3">
        <li
          :for={adapter <- @adapters}
          id={"set-up-adapter-#{adapter.public_id}"}
          class="flex items-center gap-3 rounded-box border border-line bg-base-100 px-4 py-3"
        >
          <IntegrationComponents.mark class="size-5" />
          <p class="min-w-0 flex-1 truncate font-medium">{Adapters.title(adapter)}</p>
          <span
            :if={MapSet.member?(@connected, adapter.id)}
            id={"set-up-adapter-#{adapter.public_id}-connected"}
            class="q-sdot q-sdot-completed text-[13px]/5"
          >
            <i aria-hidden="true"></i><span>{gettext("Connected")}</span>
          </span>
          <span
            :if={
              not MapSet.member?(@connected, adapter.id) and MapSet.member?(@connecting, adapter.id)
            }
            id={"set-up-adapter-#{adapter.public_id}-connecting"}
            role="status"
            class="q-sdot q-sdot-pending text-[13px]/5"
          >
            <i aria-hidden="true"></i><span>{gettext("Connecting…")}</span>
          </span>
          <span
            :if={
              not MapSet.member?(@connected, adapter.id) and
                not MapSet.member?(@connecting, adapter.id)
            }
            id={"set-up-adapter-#{adapter.public_id}-not-connected"}
            class="q-sdot text-[13px]/5 text-muted"
          >
            <i aria-hidden="true"></i><span>{gettext("Not connected")}</span>
          </span>
          <IntegrationComponents.install_form
            :if={@may}
            id={"set-up-adapter-#{adapter.public_id}-connect"}
            adapter={adapter}
            variant={if MapSet.member?(@connected, adapter.id), do: "default", else: "primary"}
            action={IntegrationComponents.paths(@current_scope, adapter).install <> "?" <> URI.encode_query(back: @back)}
            ready={adapter.id in @ready}
            sending={@sending == adapter.public_id}
            label={gettext("Connect")}
          />
        </li>
      </ul>

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
        :if={!@may}
        id="set-up-who-may"
        class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
      >
        {@who_may}
      </p>

      <div id="set-up-later" class="grid gap-1 text-[13px]/5 text-muted">
        <p :if={@step == :sources}>
          {gettext(
            "%{organisation} connects each system once. Each workspace then picks what it uses.",
            organisation: @flow.organisation.name
          )}
        </p>
        <p>
          {gettext("You can change these or add more later in Organisation settings › Integrations.")}
        </p>
      </div>

      <.acts steps={@steps} page_path={@page_path} next_path={@next_path} skip={!@done} />

      <:context :if={@step == :sources or guides(@adapters, @ready) != []}>
        <p :if={@step == :sources} id="set-up-what">
          {pgettext("plain", "Bring tickets in from a system this instance has set up.")}
        </p>
        <p :for={adapter <- @adapters} :if={adapter.id in @ready}>
          {gettext(
            "Connect opens %{adapter} in this tab, and %{adapter} sends you back to Qory Apiary after its steps.",
            adapter: Adapters.title(adapter)
          )}
        </p>
        <SetUpComponents.outside
          :for={{adapter, guide} <- guides(@adapters, @ready)}
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

      <p :if={@existing} id="set-up-model-key" class="text-[13.5px]/5">
        {gettext("%{organisation} has a key for %{provider}.",
          organisation: @flow.organisation.name,
          provider: @existing.name
        )}
      </p>

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
        <.input
          :if={!@existing}
          field={@form[:provider]}
          type="choice"
          label={gettext("Provider")}
          options={ProviderPage.provider_options()}
        />
        <.input
          :if={!@existing}
          field={@form[:key]}
          id={"set-up-model-key-#{@attempt}"}
          type="password"
          value={nil}
          label={gettext("Key")}
          hint={gettext("Qory Apiary stores the key encrypted, and nobody can view it again.")}
          autocomplete="off"
          spellcheck="false"
          phx-update="ignore"
          required
        />
        <.input
          :for={name <- (!@existing && @chosen && Provider.address_settings(@chosen)) || []}
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
        <p class="text-[13px]/5 text-muted">
          {gettext(
            "You can change these or add more later in Organisation settings › Model providers."
          )}
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
          {gettext("A model provider's key lets runs in %{organisation} call a model.",
            organisation: @flow.organisation.name
          )}
        </p>
        <ProviderPage.get_key :if={@may and !@existing} id="set-up-get-key" chosen={@chosen} />
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

  defp flow_step(%{step: step} = assigns) when step in [:sources_used, :destinations_used] do
    ~H"""
    <SetUpComponents.frame steps={@steps} title={@title} page={@page_path}>
      <SetUpComponents.heading>{@page_title}</SetUpComponents.heading>

      <TickListComponents.tick_list
        id="set-up"
        list={tick_list(@step)}
        groups={@groups}
        workspace={@flow.workspace}
        organisation={@flow.organisation}
        may={@may}
        who_may={@who_may}
        may_connect={@may_connect}
        who_connects={@who_connects}
        connect_path={@connect_path}
      />

      <p id="set-up-later" class="text-[13px]/5 text-muted">
        <span :if={@step == :sources_used}>
          {gettext("You can change this later in Workspace settings › Work sources.")}
        </span>
        <span :if={@step == :destinations_used}>
          {gettext("You can change this later in Workspace settings › Destinations.")}
        </span>
      </p>

      <.acts steps={@steps} page_path={@page_path} next_path={@next_path} skip={false} />
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
        choice: HarnessComponents.choice(assigns.form.params, assigns.linked)
      )

    ~H"""
    <SetUpComponents.frame steps={@steps} title={@title} page={@page_path}>
      <SetUpComponents.heading>{@page_title}</SetUpComponents.heading>

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
          organisation={@flow.organisation.name}
          disabled={!@may or @saving}
        />

        <.notice :if={@harness_refusal} kind={:error}>
          <span id="set-up-harness-refusal" data-reason={harness_refusal_code(@harness_refusal)}>
            {elem(@harness_refusal, 1)}
          </span>
        </.notice>

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

        <div :if={@may} class="q-su-acts">
          <SetUpComponents.back steps={@steps} page={@page_path} />
          <.button
            id="set-up-continue"
            type="submit"
            variant="primary"
            size="md"
            disabled={is_nil(@choice) or @saving}
            loading_text={gettext("Saving")}
          >
            {if @saving, do: gettext("Saving"), else: gettext("Continue")}
          </.button>
        </div>
      </.form>

      <.acts :if={!@may} steps={@steps} page_path={@page_path} next_path={@next_path} skip={!@done} />
    </SetUpComponents.frame>
    """
  end

  defp flow_step(%{step: :machines} = assigns) do
    %{pools: pools, instance_admin: admin?, enrols: enrols} = assigns

    assigns =
      assign(assigns,
        only: match?([_line], pools),
        lines: for(line <- pools, do: {pool_line_id(line), line, pool_act(line, admin?, enrols)})
      )

    ~H"""
    <SetUpComponents.frame steps={@steps} title={@title} page={@page_path}>
      <SetUpComponents.heading>{@page_title}</SetUpComponents.heading>

      <ul id="set-up-pools" class="q-choices grid gap-2">
        <li :for={{id, line, act} <- @lines} id={id} class="q-choice cursor-default">
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
end
