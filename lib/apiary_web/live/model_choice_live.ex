defmodule ApiaryWeb.ModelChoiceLive do
  # Workspace settings › Model, `/:org/:workspace/settings/model`, with the features
  # `factory` and `secrets`: the workspace's model choice (level 5, `Apiary.ModelChoices`).
  #
  # Runtime, a select of the runtime catalogue (`Apiary.Kinds.Runtimes`), shown only while
  # the catalogue has more than one; with one, the choice names none and its runs use that
  # one (`Apiary.ModelChoices.default_runtime/0`). Model: a choice of the models the page
  # suggests (`Apiary.ModelChoices.suggestions/2`) for each model provider of the
  # organisation that applies to the workspace and serves the chosen runtime
  # (`Apiary.Kinds.Providers.serve/2`), grouped by provider where there are several, each
  # provider's list ending with Another model, which opens a text field for any model id.
  # With none, one line per cause says what to do instead (`unserved/3`). Effort shows
  # where the chosen model has effort values to choose from. With no choice saved, the first provider's first
  # model is selected. Save writes the choice (`Apiary.ModelChoices.put_choice/4`), keeping
  # the key and the tiers the place had while its provider stays the same; each refusal
  # shows its text under the field it is about.
  #
  # Fallbacks, below them: the providers runs use, in order, while every key of the chosen
  # provider is in cooldown, each a row of Provider, Model, Another model and Effort as
  # above, with Move up, Move down and Remove. Add fallback adds a row of the first
  # provider left: one that applies to the workspace and serves the chosen runtime, and is
  # neither the chosen provider nor in a row. A new row's model, and a row's model after
  # its provider changes, is the chosen model where the provider has a model of the same
  # id, else the provider's first. Save writes the rows with the choice; each refusal
  # shows under its row's field.
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
  alias Apiary.Kinds.{Providers, Runtime, Runtimes}
  alias Apiary.ModelChoices.ModelChoice
  alias ApiaryWeb.{SettingsComponents, UserAuth}

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

    runtime =
      case ModelChoices.runtime(choice && choice.runtime) do
        {:ok, runtime} -> runtime
        :error -> ModelChoices.default_runtime()
      end

    applicable = Enum.filter(providers, &applies?(&1, scope.workspace.id))
    stored = if choice, do: Enum.map(choice.fallbacks, & &1.connection), else: []

    socket
    |> assign(
      applicable: applicable,
      known: Map.new(applicable ++ stored, &{&1.public_id, &1}),
      runtimes: Runtimes.list(),
      choice: choice
    )
    |> assign_runtime(runtime)
    |> then(&assign_form(&1, choice_params(choice, &1.assigns.providers), []))
    |> then(&assign_fallbacks(&1, fallback_rows(choice, &1.assigns.providers), %{}))
  end

  # The runtime the form has chosen, and the providers that serve it, each with its
  # suggestions; `described` is each applicable provider with its description, or why it
  # has none (`Apiary.Connections.provider/1`).
  defp assign_runtime(socket, %Runtime{} = runtime) do
    described =
      for provider <- socket.assigns.applicable, do: {provider, Connections.provider(provider)}

    providers =
      for {provider, {:ok, description}} <- described,
          Providers.serve(description, runtime) == :ok,
          do: %{provider: provider, models: ModelChoices.suggestions(provider, runtime)}

    assign(socket, runtime: runtime, providers: providers, described: described)
  end

  # Why no provider serves the chosen runtime, as the lines the page shows: each provider
  # whose description changed or is gone, `{:changed, provider}` or `{:unknown,
  # provider}`; then, while a provider with its description is left, `:other_runtime`
  # when another runtime of the catalogue has a provider that serves it, else `:none`.
  defp unserved(described, runtime, runtimes) do
    descriptions = for {_provider, {:ok, description}} <- described, do: description

    gone =
      for {provider, {:error, why}} <- described,
          do: {if(why == :provider_changed, do: :changed, else: :unknown), provider}

    served_elsewhere? =
      Enum.any?(runtimes, fn other ->
        other.name != runtime.name and
          Enum.any?(descriptions, &(Providers.serve(&1, other) == :ok))
      end)

    cond do
      descriptions == [] -> gone
      served_elsewhere? -> gone ++ [:other_runtime]
      true -> gone ++ [:none]
    end
  end

  # Whether the form shows Runtime: while the catalogue has more than one.
  defp runtimes?(runtimes), do: length(runtimes) > 1

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

  # The form's values for `choice`: its provider's model, or Another model with its id;
  # with no choice, or one of a provider not listed, the first provider's first model.
  defp choice_params(%ModelChoice{} = choice, providers) do
    case Enum.find(providers, &(&1.provider.id == choice.connection_id)) do
      nil ->
        choice_params(nil, providers)

      %{provider: provider, models: models} ->
        model_id = choice.model_id || Connections.default_model(provider)

        if Enum.any?(models, &(&1.id == model_id)),
          do: %{"model" => option(provider, model_id), "effort" => choice.effort || ""},
          else: %{"model" => option(provider, nil), "other" => model_id || "", "effort" => ""}
    end
  end

  defp choice_params(nil, [%{provider: provider, models: models} | _rest]) do
    case models do
      [%{id: id} | _] -> %{"model" => option(provider, id)}
      [] -> %{"model" => option(provider, nil)}
    end
  end

  defp choice_params(nil, []), do: %{}

  # An option's value: the provider's public id, then a slash and the model id; the
  # provider's public id alone for its Another model. A public id has no slash.
  defp option(%Connection{public_id: id}, nil), do: id
  defp option(%Connection{public_id: id}, model_id), do: id <> "/" <> model_id

  # What an option's value chose: `{provider, model}`, `{provider, :other}`, or nil.
  defp chosen(value, providers) when is_binary(value) do
    {id, model_id} =
      case String.split(value, "/", parts: 2) do
        [id, model_id] -> {id, model_id}
        [id] -> {id, :other}
      end

    case Enum.find(providers, &(&1.provider.public_id == id)) do
      nil -> nil
      %{models: models} = entry -> {entry, find_model(models, model_id)}
    end
  end

  defp chosen(_value, _providers), do: nil

  defp find_model(_models, :other), do: :other
  defp find_model(models, model_id), do: Enum.find(models, &(&1.id == model_id))

  ## Fallbacks

  # The rows of the place's fallbacks, in their order, as the form sends them: `provider`,
  # the provider's public id, and `model`, `other` and `effort` as the choice's.
  defp fallback_rows(nil, _providers), do: []

  defp fallback_rows(%ModelChoice{fallbacks: fallbacks}, providers) do
    for fallback <- fallbacks do
      provider = fallback.connection
      models = models_of(providers, provider)
      model_id = fallback.model_id || Connections.default_model(provider)

      model =
        if Enum.any?(models, &(&1.id == model_id)),
          do: %{
            "model" => option(provider, model_id),
            "other" => "",
            "effort" => fallback.effort || ""
          },
          else: %{"model" => option(provider, nil), "other" => model_id || "", "effort" => ""}

      Map.put(model, "provider", provider.public_id)
    end
  end

  defp models_of(providers, %Connection{id: id}) do
    case Enum.find(providers, &(&1.provider.id == id)) do
      %{models: models} -> models
      nil -> []
    end
  end

  defp assign_fallbacks(socket, rows, errors),
    do: assign(socket, fallbacks: rows, fallback_errors: errors)

  # The row for `provider`: the chosen model where the provider has a model of the same
  # id, else its first, else Another model; with the chosen effort where that model has it.
  defp new_row(socket, %Connection{} = provider) do
    models = models_of(socket.assigns.providers, provider)
    params = socket.assigns.form.params

    same =
      case socket.assigns.chosen do
        {_entry, %{id: id}} -> Enum.find(models, &(&1.id == id))
        {_entry, :other} -> Enum.find(models, &(&1.id == blank_to_nil(params["other"])))
        nil -> nil
      end

    case same || List.first(models) do
      nil ->
        %{
          "provider" => provider.public_id,
          "model" => option(provider, nil),
          "other" => "",
          "effort" => ""
        }

      model ->
        effort = if params["effort"] in model.effort, do: params["effort"], else: ""

        %{
          "provider" => provider.public_id,
          "model" => option(provider, model.id),
          "other" => "",
          "effort" => effort
        }
    end
  end

  # The rows as the form sent them, in their order. A row whose provider changed, or whose
  # model is not of its provider, takes `new_row/2`'s model. With no rows sent, the rows
  # are as they were: a form without them, or with them off for a reader.
  defp sent_rows(socket, %{"fallbacks" => %{} = sent}) do
    old = socket.assigns.fallbacks

    sent
    |> Enum.flat_map(fn {index, row} ->
      case Integer.parse(index) do
        {i, ""} when is_map(row) -> [{i, row}]
        _other -> []
      end
    end)
    |> Enum.sort()
    |> Enum.map(fn {i, row} ->
      row = Map.merge(Enum.at(old, i, %{}), Map.take(row, ~w(provider model other effort)))
      row = Map.merge(%{"model" => "", "other" => "", "effort" => ""}, row)

      case socket.assigns.known[row["provider"]] do
        %Connection{public_id: id} = provider ->
          if String.split(row["model"] || "", "/", parts: 2) |> hd() == id and
               row["provider"] == (Enum.at(old, i) || %{})["provider"],
             do: row,
             else: new_row(socket, provider)

        nil ->
          row
      end
    end)
  end

  defp sent_rows(socket, _params), do: socket.assigns.fallbacks

  # The providers a new row may have: those that serve the chosen runtime, but the chosen
  # provider and those of the rows but `except`.
  defp left(assigns, except \\ nil) do
    taken =
      for {row, i} <- Enum.with_index(assigns.fallbacks), i != except, do: row["provider"]

    main = main_provider(assigns)

    for %{provider: provider} <- assigns.providers,
        provider.public_id not in taken,
        main == nil or provider.id != main.id,
        do: provider
  end

  defp main_provider(%{chosen: {%{provider: provider}, _model}}), do: provider
  defp main_provider(_assigns), do: nil

  # A row's providers: those `left/2` offers it, with the row's provider, in the order of
  # the page.
  defp row_providers(assigns, row, index) do
    offered = left(assigns, index)

    case assigns.known[row["provider"]] do
      %Connection{} = provider ->
        if Enum.any?(offered, &(&1.id == provider.id)), do: offered, else: offered ++ [provider]

      nil ->
        offered
    end
  end

  # What a row's model chose: a model of the provider's list, `:other`, or nil.
  defp row_model(assigns, row) do
    with %Connection{public_id: id} = provider <- assigns.known[row["provider"]],
         [^id | rest] <- String.split(row["model"] || "", "/", parts: 2) do
      case rest do
        [] -> :other
        [model_id] -> Enum.find(models_of(assigns.providers, provider), &(&1.id == model_id))
      end
    else
      _other -> nil
    end
  end

  # The fallbacks a save sends: each row's provider, model and effort, as the choice's.
  defp fallback_attrs(assigns, rows) do
    for row <- rows do
      case row_model(assigns, row) do
        :other ->
          %{provider: row["provider"], model: blank_to_nil(row["other"]), effort: nil}

        %{id: id} ->
          %{provider: row["provider"], model: id, effort: blank_to_nil(row["effort"])}

        nil ->
          %{provider: row["provider"], model: nil, effort: nil}
      end
    end
  end

  # The refusals of the fallbacks, by the row's index: each on its row's field, the
  # model's under Another model when that is chosen.
  defp fallback_field_errors(assigns, rows, errors) do
    errors
    |> Enum.flat_map(fn
      {:fallbacks, {message, opts}} ->
        index = opts[:fallback]

        if is_integer(index) do
          row = Enum.at(rows, index) || %{}

          field =
            case opts[:field] do
              :model -> if row_model(assigns, row) == :other, do: :other, else: :model
              field when field in [:provider, :effort] -> field
              _other -> :model
            end

          [{index, {field, {message, opts}}}]
        else
          []
        end

      _other ->
        []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp row_form(row, index, errors) do
    to_form(row,
      as: "model_choice[fallbacks][#{index}]",
      id: "model_choice_fallbacks_#{index}",
      errors: Map.get(errors, index, [])
    )
  end

  defp assign_form(socket, params, errors) do
    params =
      errors
      |> Enum.reduce(params, fn {field, _}, p -> Map.put_new(p, "#{field}", "") end)
      |> Map.put("runtime", socket.assigns.runtime.name)

    assign(socket,
      form: to_form(params, as: :model_choice, errors: errors),
      chosen: chosen(params["model"], socket.assigns.providers)
    )
  end

  @impl true
  # A change of the runtime lists the providers that serve it, and keeps the chosen model
  # while its provider is one of them.
  def handle_event("choose", %{"model_choice" => params}, socket) do
    socket =
      with name when name != socket.assigns.runtime.name <- params["runtime"],
           {:ok, runtime} <- Runtimes.fetch(name) do
        assign_runtime(socket, runtime)
      else
        _same -> socket
      end

    params =
      if chosen(params["model"], socket.assigns.providers),
        do: params,
        else: Map.merge(params, choice_params(nil, socket.assigns.providers))

    socket = assign_form(socket, params, [])
    {:noreply, assign_fallbacks(socket, sent_rows(socket, params), %{})}
  end

  def handle_event("add_fallback", _params, %{assigns: %{writes: true}} = socket) do
    case left(socket.assigns) do
      [provider | _rest] ->
        rows = socket.assigns.fallbacks ++ [new_row(socket, provider)]
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
    rows = sent_rows(socket, params)
    socket = assign_fallbacks(socket, rows, %{})

    case chosen(params["model"], socket.assigns.providers) do
      nil ->
        {:noreply, assign_form(socket, params, model: {"is invalid", []})}

      {%{provider: provider}, model} ->
        model_id = if model == :other, do: blank_to_nil(params["other"]), else: model && model.id
        effort = if model == :other, do: nil, else: blank_to_nil(params["effort"])

        attrs =
          %{
            runtime: if(runtimes?(socket.assigns.runtimes), do: socket.assigns.runtime.name),
            provider: provider.public_id,
            model: model_id,
            effort: effort,
            fallbacks: fallback_attrs(socket.assigns, rows)
          }
          |> Map.merge(kept(socket.assigns.choice, provider))

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
             |> assign_form(params, field_errors(main, model))
             |> assign_fallbacks(rows, fallback_field_errors(socket.assigns, rows, fallbacks))}

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

  # The key and the tiers of the place's choice, kept while its provider stays the same.
  defp kept(%ModelChoice{connection_id: id} = choice, %Connection{id: id}),
    do: %{key: choice.value_id, tiers: choice.tiers}

  defp kept(_choice, _provider), do: %{}

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # Each refusal on the field it is about: the model's under Another model when that is
  # chosen, the effort's under Effort, every other under Model.
  defp field_errors(errors, model) do
    for {field, error} <- errors do
      case field do
        :model when model == :other -> {:other, error}
        :effort -> {:effort, error}
        :runtime -> {:runtime, error}
        _other -> {:model, error}
      end
    end
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

  # The choice's options: each provider's models, its title over its id, then its Another
  # model, which a search keeps in view, in a group named after the provider where there
  # are several.
  defp options([%{provider: provider, models: models}]), do: provider_options(provider, models)

  defp options(providers),
    do:
      for(%{provider: p, models: models} <- providers, do: {p.name, provider_options(p, models)})

  defp provider_options(provider, models),
    do:
      for(
        model <- models,
        do: %{
          value: option(provider, model.id),
          title: model.title,
          subtitle: model.id,
          mono: :subtitle
        }
      ) ++
        [
          %{
            value: option(provider, nil),
            title: gettext("Another model"),
            subtitle: gettext("A model id this list leaves out."),
            keep: true
          }
        ]

  defp line_id({cause, %Connection{public_id: id}}), do: "model-#{cause}-#{id}"
  defp line_id(cause), do: "model-#{cause}"

  defp unserved_text({:changed, provider}, scope, _runtime),
    do:
      rich_gettext(
        "Add %{provider} again in %{place}: its description changed after it was added.",
        provider: {:b, provider.name},
        place: providers_link(scope)
      )

  defp unserved_text({:unknown, provider}, scope, _runtime),
    do:
      rich_gettext(
        "Add another model provider in %{place}: Qory Apiary no longer has the description %{provider} was added from.",
        provider: {:b, provider.name},
        place: providers_link(scope)
      )

  defp unserved_text(:other_runtime, scope, runtime),
    do:
      rich_gettext(
        "Choose another runtime: no model provider of %{organisation} serves %{runtime}.",
        organisation: scope.organisation.name,
        runtime: runtime.title
      )

  defp unserved_text(:none, scope, runtime),
    do:
      rich_gettext(
        "Add a model provider that serves %{runtime} in %{place}. None of the model providers of %{organisation} serves %{runtime}.",
        runtime: runtime.title,
        organisation: scope.organisation.name,
        place: providers_link(scope)
      )

  defp providers_link(scope),
    do:
      {:link, ~p"/#{scope.organisation}/settings/model-providers",
       gettext("Organisation settings › Model providers")}

  defp efforts({_entry, %{effort: [_ | _] = effort}}), do: effort
  defp efforts(_chosen), do: []

  # What the Fallbacks part reads of the page's assigns.
  defp fallback_page(assigns),
    do:
      Map.take(
        assigns,
        ~w(writes fallbacks fallback_errors providers known chosen runtime current_scope)a
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
              "Add another model provider that serves %{runtime} in %{place}, then add it here as a fallback.",
              runtime: @page.runtime.title,
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

  # One fallback: Provider, Model, Another model and Effort, as the choice's, then Move up,
  # Move down and Remove; a group named by its place ("Fallback 2"), for whoever hears it,
  # with a rule above it from the second row on.
  defp fallback_row(assigns) do
    %{page: page, row: row, index: index} = assigns
    model = row_model(page, row)

    assigns =
      assign(assigns,
        form: row_form(row, index, page.fallback_errors),
        number: index + 1,
        providers: row_providers(page, row, index),
        model: model,
        efforts: if(match?(%{effort: [_ | _]}, model), do: model.effort, else: []),
        options:
          case page.known[row["provider"]] do
            %Connection{} = provider ->
              provider_options(provider, models_of(page.providers, provider))

            nil ->
              []
          end
      )

    ~H"""
    <li
      id={"model-fallback-#{@index}"}
      class="border-t border-line pt-4 first:border-t-0 first:pt-0"
    >
      <fieldset class="grid gap-3 sm:grid-cols-2 sm:items-start">
        <legend class="sr-only">{gettext("Fallback %{number}", number: @number)}</legend>
        <.input
          field={@form[:provider]}
          type="select"
          label={gettext("Provider")}
          options={for provider <- @providers, do: {provider.name, provider.public_id}}
          disabled={!@page.writes}
        />
        <.input
          field={@form[:model]}
          type="choice"
          label={gettext("Model")}
          options={@options}
          search
          search_label={gettext("Find a model")}
          found={gettext("%{shown} of %{total} models", shown: "%{shown}", total: "%{total}")}
          disabled={!@page.writes}
        />
        <.input
          :if={@model == :other}
          field={@form[:other]}
          type="text"
          label={gettext("Another model")}
          autocomplete="off"
          spellcheck="false"
          class="font-mono"
          disabled={!@page.writes}
        />
        <.input
          :if={@efforts != []}
          field={@form[:effort]}
          type="select"
          label={gettext("Effort")}
          prompt={gettext("Not set")}
          options={@efforts}
          disabled={!@page.writes}
        />
        <div :if={@page.writes} class="flex flex-wrap gap-2 sm:col-span-2">
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
          <.input
            :if={runtimes?(@runtimes)}
            field={@form[:runtime]}
            type="select"
            label={gettext("Runtime")}
            options={for runtime <- @runtimes, do: {runtime.title, runtime.name}}
            disabled={!@writes}
          />
          <div :if={@providers == []} id="model-unserved" class="space-y-1">
            <p
              :for={line <- unserved(@described, @runtime, @runtimes)}
              id={line_id(line)}
              class="text-[13.5px]/5 text-muted"
            >
              <.rich text={unserved_text(line, @current_scope, @runtime)} />
            </p>
          </div>
          <.input
            :if={@providers != []}
            field={@form[:model]}
            type="choice"
            label={gettext("Model")}
            options={options(@providers)}
            search
            search_label={gettext("Find a model")}
            found={gettext("%{shown} of %{total} models", shown: "%{shown}", total: "%{total}")}
            disabled={!@writes}
          />
          <.input
            :if={match?({_, :other}, @chosen)}
            field={@form[:other]}
            type="text"
            label={gettext("Another model")}
            autocomplete="off"
            spellcheck="false"
            class="font-mono"
            disabled={!@writes}
          />
          <.input
            :if={efforts(@chosen) != []}
            field={@form[:effort]}
            type="select"
            label={gettext("Effort")}
            prompt={gettext("Not set")}
            options={efforts(@chosen)}
            disabled={!@writes}
          />
          <.fallbacks
            :if={main_provider(assigns)}
            page={fallback_page(assigns)}
            provider={main_provider(assigns)}
          />
          <SettingsComponents.save id="model-save">
            <.button
              :if={@writes and @providers != []}
              id="model-submit"
              type="submit"
              variant="primary"
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
              "The default model for runs in %{workspace}. A workflow or a target can set another model for its runs. If %{workspace} sets none, its runs use the model of %{organisation}.",
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
