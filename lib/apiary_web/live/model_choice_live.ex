defmodule ApiaryWeb.ModelChoiceLive do
  # Workspace settings › Model, `/:org/:workspace/settings/model`, with the features
  # `factory` and `secrets`: the workspace's model choice (level 5, `Apiary.ModelChoices`),
  # under Default models.
  #
  # Provider: each model provider of the organisation that applies to the workspace and
  # is offered (`Apiary.Kinds.Providers.offered?/1`), by its name; the saved choice's
  # provider stays listed while it is not offered. Runs take the chosen provider's keys.
  # A provider that works with no runtime of the catalogue (`Apiary.Kinds.Providers.runtimes/1`)
  # is listed too: chosen, it shows "<Provider> works with no runtime in this version of
  # Qory Apiary. Pick another provider." under Provider, and Save writes nothing. With no
  # provider that works with a runtime, one line per cause says what to do instead
  # (`unserved/1`). Then the tiers of the provider, Thinking, Balanced and Light, each a
  # Model and an Effort, as `ApiaryWeb.ModelTiers` draws them. Then Runtime
  # (`ApiaryWeb.ModelTiers.runtime_part/1`): the runtimes the provider serves, as text
  # where it serves one, else a select, with a line of why. The runtime is the saved
  # choice's while the provider serves it, else the first it serves; a change of Provider
  # keeps the runtime while the new provider serves it, else moves to its first. A change
  # of the runtime keeps the models, and an effort the runtime does not accept goes back
  # to Not set. With no choice saved, the first provider is chosen and the tiers are
  # empty. Save is enabled once every tier of the choice and of each fallback has a
  # model; it writes the provider, the tiers, the runtime and the fallbacks
  # (`Apiary.ModelChoices.put_choice/4`), and each refusal shows its text under the field
  # it is about.
  #
  # Fallbacks, below Runtime: the providers runs use, in order, while every key of the
  # chosen provider is in cooldown. Each row has Provider, the tiers of its provider, as
  # the choice's, and Runtime, the runtimes its provider serves, with Move up, Move down
  # and Remove. A row's Provider lists the providers that are offered and serve a
  # runtime, but the chosen provider and those of the other rows. Add fallback adds a row
  # of the first provider left. A new row, and a row whose provider changes, starts with
  # empty tiers and on the choice's runtime where its provider serves it, else on the
  # first runtime its provider serves. A stored row shows its stored runtime. A change of
  # a row's Runtime keeps its models, and an effort that runtime does not accept goes back
  # to Not set. Save writes the rows with the choice; each refusal shows under its row's
  # field.
  #
  # Every member reads it (`connection.read`); owners and admins change it
  # (`model_choice.write`), and anyone else sees the fields disabled, no Save, and one line
  # of who changes it. The context asks again.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  on_mount {ApiaryWeb.Features, :secrets}
  on_mount {ApiaryWeb.Access, :"connection.read"}

  alias Apiary.{Access, Connections, ModelChoices}
  alias Apiary.Connections.Connection
  alias Apiary.Kinds.{Providers, Runtimes}
  alias Apiary.ModelChoices.ModelChoice
  alias ApiaryWeb.{ModelTiers, SettingsComponents, UserAuth}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       sections: SettingsComponents.sections(scope, :workspace),
       writes: Access.can?(scope, :"model_choice.write", scope.workspace),
       page_title: SettingsComponents.page_title(scope, :workspace, [gettext("Model")])
     )
     |> load()}
  end

  # The providers that apply to the workspace, the runtime of the workspace's choice, and
  # the form as that choice sets it.
  defp load(socket) do
    scope = socket.assigns.current_scope
    {:ok, providers} = Connections.list_providers(scope)
    choice = workspace_choice(scope)
    applicable = Enum.filter(providers, &applies?(&1, scope.workspace.id))
    stored = if choice, do: choice.fallbacks, else: []

    described =
      for provider <- applicable, do: {provider, Connections.provider(provider)}

    socket
    |> assign(
      applicable: applicable,
      described: described,
      known: Map.new(applicable ++ Enum.map(stored, & &1.connection), &{&1.public_id, &1}),
      choice: choice,
      fallback_stored:
        Map.new(stored, fn fallback ->
          {fallback.connection.public_id,
           %{
             provider_id: fallback.connection_id,
             tiers: ModelTiers.values(fallback.tiers),
             runtime: fallback.runtime
           }}
        end)
    )
    |> assign_entry(choice)
    |> then(&assign_fallbacks(&1, fallback_rows(stored, &1.assigns.providers), %{}))
  end

  # The provider of the saved choice and its tiers, or the first provider with no tiers;
  # the runtime of the saved choice while the provider serves it.
  defp assign_entry(socket, choice) do
    name = (choice && choice.runtime) || ModelChoices.default_runtime().name
    socket = assign_providers(socket, name)
    entries = socket.assigns.entries
    entry = ModelTiers.chosen(entries, choice) || List.first(entries)
    socket = settle(socket, entry, name)
    entry = entry && ModelTiers.find(socket.assigns.entries, entry.value)

    socket
    |> assign(
      entry: entry,
      tiers: ModelTiers.params(choice, entry),
      stored: ModelTiers.stored(choice)
    )
    |> assign_form(%{}, [])
  end

  # `providers`: the providers that are offered (`Apiary.Kinds.Providers.offered?/1`),
  # each with the `runtimes` it serves (`Apiary.Kinds.Providers.runtimes/1`), none for
  # one that works with no runtime, the one of them the form would run
  # (`ApiaryWeb.ModelTiers.runtime/2` for `name`), its suggestions for that runtime
  # (`models`) and for each runtime it serves (`models_by`, by the runtime's name), its
  # catalogue `title`, whether its description lists no models (`free`), and why it works
  # with no runtime (`unfit`, nil where it serves one); and their entries
  # (`ApiaryWeb.ModelTiers.entries/2`). `described` is each applicable provider with its
  # description, or why it has none (`Apiary.Connections.provider/1`). The provider of
  # the saved choice, and the provider of each saved fallback, stay listed while they are
  # not offered, so a save keeps them, with their tiers and runtime, unless the person
  # chooses another; no other row is offered them (`left/2`), and the choice's Provider
  # lists only the choice's (`ApiaryWeb.ModelTiers.entries/2`). The choice's provider
  # stays listed too while its description cannot be read, so Provider keeps it with a
  # line under it (`provider_line/1`) and no other provider in its place.
  defp assign_providers(socket, name) do
    saved = socket.assigns.choice && socket.assigns.choice.connection_id

    kept =
      MapSet.new(Map.values(socket.assigns.fallback_stored), & &1.provider_id)
      |> MapSet.put(saved)

    providers =
      for {provider, read} <- socket.assigns.described,
          entry <-
            provider_entries(provider, read, provider.id == saved, provider.id in kept, name),
          do: entry

    assign(socket,
      providers: providers,
      entries: ModelTiers.entries(providers, socket.assigns.choice)
    )
  end

  defp provider_entries(provider, {:ok, description}, _main?, saved?, name) do
    runtimes = Providers.runtimes(description)
    offered = Providers.offered?(description)
    runtime = ModelTiers.runtime(runtimes, name)
    models_by = Map.new(runtimes, &{&1.name, ModelChoices.suggestions(provider, &1)})

    if offered or saved? do
      [
        %{
          provider: provider,
          runtimes: runtimes,
          runtime: runtime,
          title: description.title,
          models: if(runtime, do: models_by[runtime.name], else: []),
          models_by: models_by,
          free: Connections.provider_models(description) == [],
          offered: offered,
          unfit: if(runtimes == [], do: :no_runtime)
        }
      ]
    else
      []
    end
  end

  defp provider_entries(provider, {:error, why}, true, _saved?, _name),
    do: [
      %{
        provider: provider,
        runtimes: [],
        runtime: nil,
        title: provider.name,
        models: [],
        models_by: %{},
        free: false,
        offered: false,
        unfit: why
      }
    ]

  defp provider_entries(_provider, {:error, _why}, false, _saved?, _name), do: []

  # The line under Provider while the chosen provider works with no runtime, or, for the
  # saved choice's provider, its description cannot be read: "<Provider> works with no
  # runtime in this version of Qory Apiary. Pick another provider.", or the page's line of
  # why the provider serves nothing (`unserved_text/2`); nil for any other provider. A
  # check that ran out of time or crashed has no line: the next read checks it again.
  defp provider_line(%{entry: %{provider: provider}, providers: providers} = assigns) do
    case provider_entry(providers, provider) do
      %{unfit: :no_runtime, title: title} ->
        ModelTiers.no_runtime_line(title)

      %{unfit: :provider_changed} ->
        unserved_text({:changed, provider}, assigns.current_scope)

      %{unfit: :provider_unchecked} ->
        nil

      %{unfit: why} when not is_nil(why) ->
        unserved_text({:unknown, provider}, assigns.current_scope)

      _fits ->
        nil
    end
  end

  defp provider_line(_assigns), do: nil

  # The runtime of the form for `entry`: the one named `name` while its provider serves
  # it, else the first it serves; with no provider, or one that serves no runtime, the
  # one named `name`, else the default. The providers are listed again for that runtime
  # where it is another.
  defp settle(socket, entry, name) do
    runtime =
      case entry && provider_entry(socket.assigns.providers, entry.provider) do
        %{runtime: runtime} when not is_nil(runtime) ->
          runtime

        _none ->
          case ModelChoices.runtime(name) do
            {:ok, runtime} -> runtime
            :error -> ModelChoices.default_runtime()
          end
      end

    socket = if runtime.name == name, do: socket, else: assign_providers(socket, runtime.name)
    assign(socket, runtime: runtime)
  end

  defp provider_entry(providers, %Connection{id: id}),
    do: Enum.find(providers, &(&1.provider.id == id))

  defp provider_entry(_providers, _provider), do: nil

  # Why no provider serves a runtime of the catalogue, as the lines the page shows: each
  # provider whose settings no longer fit the catalogue's entry, `{:changed, provider}`,
  # or whose kind the catalogue no longer has, `{:unknown, provider}`
  # (`Connections.provider/1`); then, while a provider with its description is left,
  # `:none`. A provider whose settings check ran out of time or crashed has no line: it
  # serves nothing on this read, and the next read checks it again. A described provider
  # that is not offered (`Apiary.Kinds.Providers.offered?/1`) serves no runtime here.
  defp unserved(described) do
    gone =
      for {provider, {:error, why}} <- described,
          why != :provider_unchecked,
          do: {if(why == :provider_changed, do: :changed, else: :unknown), provider}

    if Enum.any?(described, &match?({_provider, {:ok, _description}}, &1)),
      do: gone ++ [:none],
      else: gone
  end

  defp applies?(%Connection{applies_to: "all"}, _workspace_id), do: true

  defp applies?(%Connection{workspaces: workspaces}, workspace_id),
    do: Enum.any?(workspaces, &(&1.workspace_id == workspace_id))

  # The workspace's choice at level 5, nil for none.
  defp workspace_choice(scope) do
    {:ok, choices} = ModelChoices.list_choices(scope)
    id = scope.workspace.id

    Enum.find(choices, fn choice ->
      choice.workspace_id == id and is_nil(choice.target_id) and is_nil(choice.workflow)
    end)
  end

  ## Fallbacks

  # The rows of the stored fallbacks, in their order, as the form sends them: `provider`,
  # the provider's public id, `runtime`, the stored runtime's name, or the first runtime
  # the provider serves where it no longer serves that one, and `tiers`, the tiers'
  # values (`ApiaryWeb.ModelTiers.values/1`).
  defp fallback_rows(fallbacks, providers) do
    for fallback <- fallbacks do
      runtime =
        case provider_entry(providers, fallback.connection) do
          %{runtimes: runtimes} -> ModelTiers.runtime(runtimes, fallback.runtime)
          nil -> nil
        end

      %{
        "provider" => fallback.connection.public_id,
        "runtime" => (runtime && runtime.name) || fallback.runtime,
        "tiers" => ModelTiers.values(fallback.tiers)
      }
    end
  end

  defp assign_fallbacks(socket, rows, errors),
    do: assign(socket, fallbacks: rows, fallback_errors: errors)

  # The entry of `providers` of the provider with the public id `public_id`, nil for none.
  defp entry_of(providers, public_id),
    do: Enum.find(providers, &(&1.provider.public_id == public_id))

  # The runtime of `row` among those its provider serves, nil for none.
  defp row_runtime(page, row) do
    case entry_of(page.providers, row["provider"]) do
      %{runtimes: runtimes} -> Enum.find(runtimes, &(&1.name == row["runtime"]))
      nil -> nil
    end
  end

  # The provider entry of `row` (`ApiaryWeb.ModelTiers.entry/3`), with its provider's
  # models for the row's runtime; nil for a provider the page does not list.
  defp row_entry(page, row) do
    with %{} = entry <- entry_of(page.providers, row["provider"]) do
      models = Map.get(entry.models_by, row["runtime"], [])
      ModelTiers.entry(entry.provider, models, entry.free)
    end
  end

  # The row for the provider of `entry`: the choice's runtime where the provider serves
  # it, else the first it serves, and no models.
  defp new_row(socket, entry) do
    runtime = ModelTiers.runtime(entry.runtimes, socket.assigns.runtime.name)

    %{
      "provider" => entry.provider.public_id,
      "runtime" => runtime && runtime.name,
      "tiers" => ModelTiers.blank()
    }
  end

  # The rows as the form sent them, in their order. A row whose provider changed takes
  # `new_row/2`. A row of the same provider takes the runtime sent while the provider
  # serves it, and the tiers sent, fitted to the provider and that runtime
  # (`ApiaryWeb.ModelTiers.sent/5`): a change of the runtime keeps the models, and an
  # effort the runtime does not accept goes back to Not set. A row sent with a provider
  # the page does not list, which no select of the page offers, is marked `"unknown"`,
  # and a save refuses it (`unknown_rows/1`). With no rows sent, the rows are as they
  # were: a form without them, or with them off for a reader.
  defp sent_rows(socket, %{"fallbacks" => %{} = sent}) do
    old = socket.assigns.fallbacks
    page = socket.assigns

    sent
    |> Enum.flat_map(fn {index, row} ->
      case Integer.parse(index) do
        {i, ""} when is_map(row) -> [{i, row}]
        _other -> []
      end
    end)
    |> Enum.sort()
    |> Enum.map(fn {i, row} ->
      was = Enum.at(old, i)
      provider = if is_binary(row["provider"]), do: row["provider"], else: was["provider"]

      entry = entry_of(page.providers, provider)

      cond do
        entry == nil and was != nil and was["provider"] == provider ->
          was

        entry == nil ->
          %{
            "provider" => provider,
            "runtime" => nil,
            "tiers" => ModelTiers.blank(),
            "unknown" => true
          }

        was == nil or was["provider"] != provider ->
          new_row(socket, entry)

        true ->
          name = if is_binary(row["runtime"]), do: row["runtime"], else: was["runtime"]
          sent_row(page, was, row, ModelTiers.runtime(entry.runtimes, name))
      end
    end)
  end

  defp sent_rows(socket, _params), do: socket.assigns.fallbacks

  # A row of the same provider as `was`, on `runtime`, with the tiers `row` sent.
  defp sent_row(_page, was, _row, nil), do: was

  defp sent_row(page, was, row, runtime) do
    now = Map.put(was, "runtime", runtime.name)

    stored =
      page.fallback_stored
      |> Map.get(was["provider"])
      |> ModelTiers.accepted(runtime)

    tiers =
      ModelTiers.sent(
        row_entry(page, now),
        row_entry(page, was),
        was["tiers"],
        row["tiers"],
        stored
      )

    Map.put(now, "tiers", tiers)
  end

  # The providers a new row may have: those that are offered and serve a runtime, but the
  # chosen provider and those of the rows but `except`.
  defp left(assigns, except \\ nil) do
    taken =
      for {row, i} <- Enum.with_index(assigns.fallbacks), i != except, do: row["provider"]

    main = main_provider(assigns)

    for %{provider: provider, offered: true, runtimes: [_ | _]} = entry <- assigns.providers,
        provider.public_id not in taken,
        main == nil or provider.id != main.id,
        do: entry
  end

  defp main_provider(%{entry: %{provider: provider}}), do: provider
  defp main_provider(_assigns), do: nil

  # A row's providers: those `left/2` offers it, with the row's provider, in the order of
  # the page.
  defp row_providers(assigns, row, index) do
    offered = Enum.map(left(assigns, index), & &1.provider)

    case assigns.known[row["provider"]] do
      %Connection{} = provider ->
        if Enum.any?(offered, &(&1.id == provider.id)), do: offered, else: offered ++ [provider]

      nil ->
        offered
    end
  end

  # The refusals of the rows sent with a provider the page does not list, by the row's
  # index: "is invalid" on its Provider, as the workflow's fold refuses one.
  defp unknown_rows(rows) do
    for {%{"unknown" => true}, i} <- Enum.with_index(rows),
        into: %{},
        do: {i, [{:provider, {"is invalid", []}}]}
  end

  # Whether the form sent a provider that the page does not list.
  defp unknown_provider?(socket, %{"provider" => sent}) when is_binary(sent),
    do: ModelTiers.find(socket.assigns.entries, sent) == nil

  defp unknown_provider?(_socket, _params), do: false

  # Whether every row has a model in every tier.
  defp rows_complete?(rows), do: Enum.all?(rows, &ModelTiers.complete?(&1, &1["tiers"]))

  # The fallbacks a save sends: each row's provider, runtime and tiers.
  defp fallback_attrs(rows) do
    for row <- rows,
        do: %{
          provider: row["provider"],
          runtime: row["runtime"],
          tiers: ModelTiers.saved_tiers(row["tiers"])
        }
  end

  # The refusals of the fallbacks, by the row's index, each `{field, error}` on its row's
  # field: `:provider`, `:runtime`, or a tier's field as
  # `ApiaryWeb.ModelTiers.field_errors/2` places it.
  defp fallback_field_errors(rows, errors) do
    errors
    |> Enum.flat_map(fn
      {:fallbacks, {message, opts}} ->
        index = opts[:fallback]

        cond do
          not is_integer(index) ->
            []

          Keyword.has_key?(opts, :tier) or opts[:field] not in [:provider, :runtime] ->
            row = Enum.at(rows, index) || %{}
            tiers = row["tiers"] || ModelTiers.blank()

            for placed <- ModelTiers.field_errors([tiers: {message, opts}], tiers),
                do: {index, placed}

          true ->
            [{index, {opts[:field], {message, opts}}}]
        end

      _other ->
        []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp row_form(row, index, errors) do
    to_form(Map.take(row, ["provider"]),
      as: "model_choice[fallbacks][#{index}]",
      id: "model_choice_fallbacks_#{index}",
      errors: for({:provider, error} <- Map.get(errors, index, []), do: {:provider, error})
    )
  end

  # The form of Runtime and Provider, with `errors`, those of `ModelTiers.field_errors/2`:
  # each on Runtime or Provider, the tiers' as `tier_errors`.
  defp assign_form(socket, params, errors) do
    {tier_errors, field_errors} =
      Enum.split_with(errors, fn {field, _error} -> field == :tiers or is_tuple(field) end)

    params =
      params
      |> Map.take(["runtime", "provider"])
      |> Map.put("runtime", socket.assigns.runtime.name)
      |> Map.put("provider", (socket.assigns.entry && socket.assigns.entry.value) || "")

    assign(socket,
      form: to_form(params, as: :model_choice, errors: field_errors),
      tier_errors: tier_errors
    )
  end

  # The provider, the runtime and the tiers as the form sent them. A provider the page
  # does not list keeps the provider the page had, else the first. The runtime is the one
  # sent while the provider serves it, else the first it serves, so a change of Provider
  # keeps the runtime where the new provider serves it. A change of the runtime keeps the
  # models, and an effort the new runtime does not accept goes back to Not set
  # (`ApiaryWeb.ModelTiers.accepted/2`).
  defp take_sent(socket, params) do
    %{entries: entries, entry: before, tiers: old, stored: stored} = socket.assigns
    sent = if is_binary(params["provider"]), do: ModelTiers.find(entries, params["provider"])
    before = before && ModelTiers.find(entries, before.value)
    entry = sent || before || List.first(entries)

    name =
      if is_binary(params["runtime"]),
        do: params["runtime"],
        else: socket.assigns.runtime.name

    socket = socket |> assign_providers(name) |> settle(entry, name)
    entry = entry && ModelTiers.find(socket.assigns.entries, entry.value)
    stored = ModelTiers.accepted(stored, socket.assigns.runtime)
    tiers = ModelTiers.sent(entry, before, old, params["tiers"], stored)

    assign(socket, entry: entry, tiers: tiers)
  end

  @impl true
  # A change of Provider fits the runtime to the provider; a change of the runtime fits
  # the tiers' efforts to it (`take_sent/2`).
  def handle_event("choose", %{"model_choice" => params}, socket) do
    socket = socket |> take_sent(params) |> assign_form(params, [])
    {:noreply, assign_fallbacks(socket, sent_rows(socket, params), %{})}
  end

  def handle_event("add_fallback", _params, %{assigns: %{writes: true}} = socket) do
    case left(socket.assigns) do
      [entry | _rest] ->
        rows = socket.assigns.fallbacks ++ [new_row(socket, entry)]
        {:noreply, assign_fallbacks(socket, rows, %{})}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "move_fallback",
        %{"index" => index, "to" => to},
        %{assigns: %{writes: true}} = socket
      ) do
    rows = socket.assigns.fallbacks

    with {i, ""} <- Integer.parse(index),
         j = if(to == "up", do: i - 1, else: i + 1),
         true <-
           to in ["up", "down"] and i in 0..(length(rows) - 1)//1 and
             j in 0..(length(rows) - 1)//1 do
      rows = rows |> List.replace_at(i, Enum.at(rows, j)) |> List.replace_at(j, Enum.at(rows, i))
      {:noreply, assign_fallbacks(socket, rows, %{})}
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("remove_fallback", %{"index" => index}, %{assigns: %{writes: true}} = socket) do
    rows = socket.assigns.fallbacks

    # Only the index of a row: List.delete_at/2 takes -1 as the last row.
    case Integer.parse(index) do
      {i, ""} when i in 0..(length(rows) - 1)//1 ->
        {:noreply, assign_fallbacks(socket, List.delete_at(rows, i), %{})}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("save", %{"model_choice" => params}, %{assigns: %{writes: true}} = socket) do
    scope = socket.assigns.current_scope
    socket = take_sent(socket, params)
    rows = sent_rows(socket, params)
    socket = assign_fallbacks(socket, rows, %{})

    cond do
      # No provider, or one sent that no select of the page offers: refused under
      # Provider, and nothing is written.
      socket.assigns.entry == nil or unknown_provider?(socket, params) ->
        {:noreply, assign_form(socket, params, provider: {"is invalid", []})}

      # A provider that works with no runtime, or the saved one whose description cannot
      # be read: its line under Provider says why, and nothing is written.
      provider_line(socket.assigns) != nil ->
        {:noreply, assign_form(socket, params, [])}

      unknown_rows(rows) != %{} ->
        {:noreply,
         socket
         |> assign_form(params, [])
         |> assign_fallbacks(rows, unknown_rows(rows))}

      true ->
        attrs =
          socket.assigns.entry
          |> ModelTiers.attrs(socket.assigns.tiers)
          |> Map.merge(%{
            runtime: if(Runtimes.several?(), do: socket.assigns.runtime.name),
            fallbacks: fallback_attrs(rows)
          })

        case ModelChoices.put_choice(scope, :workspace, attrs) do
          {:ok, _choice} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Model saved."))
             |> load()}

          {:error, %Ecto.Changeset{errors: errors}} ->
            {fallbacks, main} =
              Enum.split_with(errors, fn {field, {_message, opts}} ->
                field == :fallbacks and is_integer(opts[:fallback])
              end)

            {:noreply,
             socket
             |> assign_form(params, ModelTiers.field_errors(main, socket.assigns.tiers))
             |> assign_fallbacks(rows, fallback_field_errors(rows, fallbacks))}

          {:error, :not_found} ->
            {:noreply, UserAuth.reload_scope(socket)}

          {:error, _forbidden} ->
            {:noreply,
             socket
             |> assign(:writes, false)
             |> put_flash(:error, who_changes(scope))}
        end
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp who_adds(scope) do
    if Access.reader(scope),
      do: ApiaryWeb.Access.reads_only(scope),
      else:
        ApiaryWeb.Access.who_may(
          scope,
          :"provider.write",
          gettext("Only owners and admins add model providers.")
        )
  end

  defp who_changes(scope) do
    if Access.reader(scope),
      do: ApiaryWeb.Access.reads_only(scope),
      else:
        ApiaryWeb.Access.who_may(
          scope,
          :"model_choice.write",
          gettext("Only owners and admins change this.")
        )
  end

  # Whether `line` is of the saved choice's provider, whose line shows under Key.
  defp saved_line?({_cause, %Connection{id: id}}, %ModelChoice{connection_id: id}), do: true
  defp saved_line?(_line, _choice), do: false

  defp line_id({cause, %Connection{public_id: id}}), do: "model-#{cause}-#{id}"
  defp line_id(cause), do: "model-#{cause}"

  defp unserved_text({:changed, provider}, scope),
    do:
      rich_gettext(
        "Add %{provider} again in %{place}: its settings no longer fit this version of Qory Apiary.",
        provider: {:b, provider.name},
        place: providers_link(scope)
      )

  defp unserved_text({:unknown, provider}, scope),
    do:
      rich_gettext(
        "Add another model provider in %{place}: Qory Apiary no longer has the description %{provider} was added from.",
        provider: {:b, provider.name},
        place: providers_link(scope)
      )

  # With no provider at all: where to add one, for whoever may add one there; for anyone
  # else, who adds one, as Organisation settings › Model providers says it.
  defp unserved_text(:none, scope) do
    if Access.can?(scope, :"provider.write", scope.organisation),
      do: rich_gettext("Add a model provider in %{place}.", place: providers_link(scope)),
      else: who_adds(scope)
  end

  defp providers_link(scope),
    do:
      {:link, ~p"/#{scope.organisation}/settings/model-providers",
       gettext("Organisation settings › Model providers")}

  # What the Fallbacks part reads of the page's assigns.
  defp fallback_page(assigns),
    do:
      Map.take(
        assigns,
        ~w(writes fallbacks fallback_errors fallback_stored providers known entry runtime current_scope)a
      )

  attr :page, :map, required: true, doc: "the page's assigns that `fallback_page/1` takes"
  attr :provider, Connection, required: true, doc: "the chosen provider"

  # The Fallbacks part: its line, a row per fallback, Add fallback, or what to add first.
  defp fallbacks(%{page: page} = assigns) do
    assigns =
      assign(assigns,
        writes: page.writes,
        rows: Enum.with_index(page.fallbacks),
        left: left(page)
      )

    ~H"""
    <SettingsComponents.part id="model-fallbacks" title={gettext("Fallbacks")}>
      <p id="model-fallbacks-line" class="text-[13.5px]/5 text-muted">
        {gettext(
          "When every key of %{provider} is in cooldown, runs use these, in order, from the next run.",
          provider: @provider.name
        )}
      </p>
      <ol :if={@rows != []} id="model-fallback-rows" class="grid gap-4">
        <.fallback_row
          :for={{row, index} <- @rows}
          page={@page}
          row={row}
          index={index}
          last={index == length(@rows) - 1}
        />
      </ol>
      <div :if={@writes}>
        <.button
          :if={@left != []}
          id="model-fallback-add"
          type="button"
          phx-click="add_fallback"
        >
          {gettext("Add fallback")}
        </.button>
        <p :if={@left == []} id="model-fallback-none" class="text-[13.5px]/5 text-muted">
          <.rich text={
            rich_gettext(
              "Add another model provider in %{place}, then add it here as a fallback.",
              place: providers_link(@page.current_scope)
            )
          } />
        </p>
      </div>
    </SettingsComponents.part>
    """
  end

  attr :page, :map, required: true
  attr :row, :map, required: true
  attr :index, :integer, required: true
  attr :last, :boolean, required: true

  # One fallback: Provider, the tiers of its provider and Runtime, as the choice's, then
  # Move up, Move down and Remove; a group named by its place ("Fallback 2"), for whoever
  # hears it, with a rule above it from the second row on.
  defp fallback_row(assigns) do
    %{page: page, row: row, index: index} = assigns
    errors = Map.get(page.fallback_errors, index, [])
    entry = entry_of(page.providers, row["provider"])
    runtime = row_runtime(page, row)

    assigns =
      assign(assigns,
        form: row_form(row, index, page.fallback_errors),
        number: index + 1,
        providers: row_providers(page, row, index),
        entry: row_entry(page, row),
        runtimes: (entry && entry.runtimes) || [],
        runtime: runtime,
        title: entry && entry.title,
        stored:
          if(runtime,
            do: ModelTiers.accepted(page.fallback_stored[row["provider"]], runtime),
            else: page.fallback_stored[row["provider"]]
          ),
        runtime_errors: for({:runtime, error} <- errors, do: translate_error(error)),
        tier_errors:
          for(
            {field, _error} = placed <- errors,
            field != :provider,
            field != :runtime,
            do: placed
          )
      )

    ~H"""
    <li
      id={"model-fallback-#{@index}"}
      class="border-t border-line pt-4 first:border-t-0 first:pt-0"
    >
      <fieldset class="grid gap-4">
        <legend class="sr-only">{gettext("Fallback %{number}", number: @number)}</legend>
        <.input
          field={@form[:provider]}
          type="select"
          label={gettext("Provider")}
          options={for provider <- @providers, do: {provider.name, provider.public_id}}
          disabled={!@page.writes}
        />
        <ModelTiers.tiers
          :if={@entry}
          id={"model-fallback-#{@index}-tiers"}
          name={"model_choice[fallbacks][#{@index}][tiers]"}
          entry={@entry}
          tiers={@row["tiers"]}
          stored={@stored}
          errors={@tier_errors}
          disabled={!@page.writes}
          fit_effort
        />
        <ModelTiers.runtime_part
          :if={@runtime}
          id={"model-fallback-#{@index}-runtime"}
          select_id={"model_choice_fallbacks_#{@index}_runtime"}
          name={"model_choice[fallbacks][#{@index}][runtime]"}
          runtimes={@runtimes}
          runtime={@runtime}
          provider={@title}
          errors={@runtime_errors}
          disabled={!@page.writes}
        />
        <div :if={@page.writes} class="flex flex-wrap gap-2">
          <.button
            id={"model-fallback-#{@index}-up"}
            type="button"
            size="xs"
            phx-click="move_fallback"
            phx-value-index={@index}
            phx-value-to="up"
            disabled={@index == 0}
            aria-label={gettext("Move fallback %{number} up", number: @number)}
          >
            {gettext("Move up")}
          </.button>
          <.button
            id={"model-fallback-#{@index}-down"}
            type="button"
            size="xs"
            phx-click="move_fallback"
            phx-value-index={@index}
            phx-value-to="down"
            disabled={@last}
            aria-label={gettext("Move fallback %{number} down", number: @number)}
          >
            {gettext("Move down")}
          </.button>
          <.button
            id={"model-fallback-#{@index}-remove"}
            type="button"
            size="xs"
            phx-click="remove_fallback"
            phx-value-index={@index}
            aria-label={gettext("Remove fallback %{number}", number: @number)}
          >
            {gettext("Remove")}
          </.button>
        </div>
      </fieldset>
    </li>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:settings}
      sections={@sections}
      section={:model}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        kind={:workspace}
        current={:model}
        title={gettext("Model")}
      >
        <p :if={@applicable == []} id="model-no-provider" class="text-[13.5px]/5 text-muted">
          <.rich text={
            rich_gettext("Add a model provider in %{place}, then choose its model here.",
              place:
                {:link, ~p"/#{@current_scope.organisation}/settings/model-providers",
                 gettext("Organisation settings › Model providers")}
            )
          } />
        </p>

        <.form
          :if={@applicable != []}
          for={@form}
          id="model-form"
          phx-change="choose"
          phx-submit="save"
          class="q-form"
          novalidate
        >
          <div id="model-default-head" class="grid gap-1">
            <h2 id="model-default-title" class="q-part-h">{gettext("Default models")}</h2>
            <p id="model-default-line" class="text-[13.5px]/5 text-muted">
              {gettext("Runs use this provider and these models when their workflow sets none.")}
            </p>
          </div>
          <div
            :if={not Enum.any?(@providers, &(&1.runtimes != []))}
            id="model-unserved"
            class="space-y-1"
          >
            <p
              :for={line <- Enum.reject(unserved(@described), &saved_line?(&1, @choice))}
              id={line_id(line)}
              class="text-[13.5px]/5 text-muted"
            >
              <.rich text={unserved_text(line, @current_scope)} />
            </p>
          </div>
          <.input
            :if={@entries != []}
            field={@form[:provider]}
            type="choice"
            label={gettext("Provider")}
            options={ModelTiers.options(@entries)}
            disabled={!@writes}
          />
          <p
            :if={provider_line(assigns)}
            id="model-provider-unfit"
            class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error"
          >
            <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
            <span><.rich text={provider_line(assigns)} /></span>
          </p>
          <ModelTiers.tiers
            :if={@entry}
            id="model-tiers"
            name="model_choice[tiers]"
            entry={@entry}
            tiers={@tiers}
            stored={ModelTiers.accepted(@stored, @runtime)}
            errors={@tier_errors}
            disabled={!@writes}
          />
          <ModelTiers.runtime_part
            :if={@entry}
            id="model-runtime"
            select_id="model_choice_runtime"
            name="model_choice[runtime]"
            runtimes={provider_entry(@providers, @entry.provider).runtimes}
            runtime={@runtime}
            provider={provider_entry(@providers, @entry.provider).title}
            errors={for {:runtime, error} <- @form.errors, do: translate_error(error)}
            disabled={!@writes}
          />
          <.fallbacks
            :if={main_provider(assigns)}
            page={fallback_page(assigns)}
            provider={main_provider(assigns)}
          />
          <SettingsComponents.save id="model-save">
            <.button
              :if={@writes and @entries != []}
              id="model-submit"
              type="submit"
              variant="primary"
              disabled={!ModelTiers.complete?(@entry, @tiers) or !rows_complete?(@fallbacks)}
              loading_text={gettext("Saving")}
            >
              {gettext("Save")}
            </.button>
            <:note :if={!@writes}>
              <span id="model-who">{who_changes(@current_scope)}</span>
            </:note>
          </SettingsComponents.save>
        </.form>
        <:context about={gettext("About models")}>
          <p id="model-line">
            {gettext(
              "The models runs in %{workspace} use: one provider, and a model and an effort for each tier. A workflow can choose another provider and models in its settings on the Workflows page. If %{workspace} sets none, its runs use the models of %{organisation}.",
              workspace: @current_scope.workspace.name,
              organisation: @current_scope.organisation.name
            )}
          </p>
        </:context>
      </SettingsComponents.layout>
    </Layouts.app>
    """
  end
end
