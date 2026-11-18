defmodule ApiaryWeb.ModelChoiceLive do
  # Workspace settings › Model, `/:org/:workspace/settings/model`, with the features
  # `factory` and `secrets`: the workspace's model choice (level 5, `Apiary.ModelChoices`),
  # under Default models.
  #
  # Key: each key of each model provider of the organisation that applies to the
  # workspace, serves a runtime of the catalogue (`Apiary.Kinds.Providers.runtimes/1`) and
  # is offered (`Apiary.Kinds.Providers.offered?/1`), as "<Provider> · <key>"; the saved
  # choice's key stays listed while it is not offered. With none, one line per cause says
  # what to do instead (`unserved/1`). Then the tiers of the key's provider, Thinking,
  # Balanced and Light, each a Model and an Effort, as `ApiaryWeb.ModelTiers` draws them.
  # Then Runtime (`ApiaryWeb.ModelTiers.runtime_part/1`): the runtimes the key's provider
  # serves, as text where it serves one, else a select, with a line of why. The runtime
  # is the saved choice's while the key's provider serves it, else the first it serves;
  # a change of Key keeps the runtime while the new provider serves it, else moves to its
  # first. A change of the runtime keeps the models, and an effort the runtime does not
  # accept goes back to Not set. With no choice saved, the first key is chosen and the
  # tiers are empty. Save is enabled once every tier has a model; it writes the key, the
  # tiers, the runtime and the fallbacks (`Apiary.ModelChoices.put_choice/4`), and each
  # refusal shows its text under the field it is about.
  #
  # Fallbacks, below Runtime: the providers runs use, in order, while every key of the
  # Key's provider is in cooldown, each a row of Provider, Model, Another model and Effort,
  # with Move up, Move down and Remove. Add fallback adds a row of the first provider
  # left: one that applies to the workspace, serves the chosen runtime and is offered, and
  # is neither the Key's provider nor in a row. A new row's model, and a row's model after
  # its provider changes, is the Thinking tier's where the provider has a model of the
  # same id, else the provider's first. A row whose provider does not serve the chosen
  # runtime, as after a change of Runtime or Key, stays with a line under its Provider,
  # and Save is disabled until it is removed or given another provider. Save writes the
  # rows with the choice; each refusal shows under its row's field.
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
    stored = if choice, do: Enum.map(choice.fallbacks, & &1.connection), else: []

    described =
      for provider <- applicable, do: {provider, Connections.provider(provider)}

    socket
    |> assign(
      applicable: applicable,
      described: described,
      known: Map.new(applicable ++ stored, &{&1.public_id, &1}),
      choice: choice
    )
    |> assign_key(choice)
    |> then(&assign_fallbacks(&1, fallback_rows(choice, &1.assigns.providers), %{}))
  end

  # The key of the saved choice and its tiers, or the first key with no tiers; the
  # runtime of the saved choice while the key's provider serves it.
  defp assign_key(socket, choice) do
    name = (choice && choice.runtime) || ModelChoices.default_runtime().name
    socket = assign_providers(socket, name)
    keys = socket.assigns.keys
    key = ModelTiers.chosen(keys, choice) || List.first(keys)
    socket = settle(socket, key, name)
    key = key && ModelTiers.find(socket.assigns.keys, key.value)

    socket
    |> assign(key: key, tiers: ModelTiers.params(choice, key), stored: ModelTiers.stored(choice))
    |> assign_form(%{}, [])
  end

  # `providers`: the providers that serve a runtime of the catalogue
  # (`Apiary.Kinds.Providers.runtimes/1`) and are offered
  # (`Apiary.Kinds.Providers.offered?/1`), each with those `runtimes`, the one of them
  # its key would run (`ApiaryWeb.ModelTiers.runtime/2` for `name`), its suggestions for
  # that runtime, whether its description lists no models (`free`), and whether it serves
  # the runtime named `name` (`serves`); and their keys (`ApiaryWeb.ModelTiers.keys/2`).
  # `described` is each applicable provider with its description, or why it has none
  # (`Apiary.Connections.provider/1`). The provider of the saved choice stays listed while
  # it is not offered, so a save keeps it unless the person chooses another; a new
  # fallback row is not offered it (`left/2`). It stays listed too while it serves no
  # runtime or its description cannot be read, with no runtimes and why (`unfit`), so Key
  # keeps the saved key with a line under it (`key_line/1`) and no other key in its place.
  defp assign_providers(socket, name) do
    saved = socket.assigns.choice && socket.assigns.choice.connection_id

    providers =
      for {provider, read} <- socket.assigns.described,
          entry <- provider_entries(provider, read, provider.id == saved, name),
          do: entry

    assign(socket, providers: providers, keys: ModelTiers.keys(providers, socket.assigns.choice))
  end

  defp provider_entries(provider, {:ok, description}, saved?, name) do
    runtimes = Providers.runtimes(description)
    offered = Providers.offered?(description)

    cond do
      runtimes != [] and (offered or saved?) ->
        runtime = ModelTiers.runtime(runtimes, name)

        [
          %{
            provider: provider,
            runtimes: runtimes,
            runtime: runtime,
            title: description.title,
            models: ModelChoices.suggestions(provider, runtime),
            free: Connections.provider_models(description) == [],
            offered: offered,
            serves: runtime.name == name,
            unfit: nil
          }
        ]

      saved? ->
        [unfit_entry(provider, description.title, {:runtimes, description})]

      true ->
        []
    end
  end

  defp provider_entries(provider, {:error, why}, true, _name),
    do: [unfit_entry(provider, provider.name, why)]

  defp provider_entries(_provider, {:error, _why}, false, _name), do: []

  defp unfit_entry(provider, title, why),
    do: %{
      provider: provider,
      runtimes: [],
      runtime: nil,
      title: title,
      models: [],
      free: false,
      offered: false,
      serves: false,
      unfit: why
    }

  # The line under Key while it is the saved choice's key and its provider serves no
  # runtime, or its description cannot be read: the refusal a save would give it
  # (`Apiary.ModelChoices.serves/3`), or the page's line of why the provider serves
  # nothing (`unserved_text/2`); nil for any other key. A check that ran out of time or
  # crashed has no line: the next read checks it again.
  defp key_line(%{key: %{provider: provider}, providers: providers} = assigns) do
    case provider_entry(providers, provider) do
      %{unfit: {:runtimes, description}} ->
        case ModelChoices.serves(description, assigns.runtime, provider.name) do
          {:error, error} -> translate_error(error)
          :ok -> nil
        end

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

  defp key_line(_assigns), do: nil

  # The runtime of the form for `key`: the one named `name` while the key's provider
  # serves it, else the first it serves; with no key, the one named `name`, else the
  # default. The providers are listed again for that runtime where it is another.
  defp settle(socket, key, name) do
    runtime =
      case key && provider_entry(socket.assigns.providers, key.provider) do
        %{runtime: runtime} when not is_nil(runtime) ->
          runtime

        # No key, or the saved key whose provider serves no runtime: the runtime named.
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

  # An option's value: the provider's public id, then a slash and the model id; the
  # provider's public id alone for its Another model. A public id has no slash.
  defp option(%Connection{public_id: id}, nil), do: id
  defp option(%Connection{public_id: id}, model_id), do: id <> "/" <> model_id

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

  # The models of `provider` for the chosen runtime: none where it does not serve it.
  defp models_of(providers, %Connection{id: id}) do
    case Enum.find(providers, &(&1.provider.id == id)) do
      %{models: models, serves: true} -> models
      _none -> []
    end
  end

  # Whether the provider of `row` is one whose description the page read and which does
  # not serve the chosen runtime: the row stays, with a line, and Save waits for it to be
  # removed or given another provider. A run would pass that fallback over at its claim,
  # and a save of it is refused (`Apiary.ModelChoices.put_choice/4`).
  defp unfit?(assigns, row) do
    sent = row["provider"]

    Enum.any?(assigns.described, fn
      {%Connection{public_id: id}, {:ok, description}} when id == sent ->
        not Providers.serves?(description, assigns.runtime)

      _other ->
        false
    end)
  end

  defp unfit_rows?(assigns), do: Enum.any?(assigns.fallbacks, &unfit?(assigns, &1))

  defp assign_fallbacks(socket, rows, errors),
    do: assign(socket, fallbacks: rows, fallback_errors: errors)

  # The row for `provider`: the Thinking tier's model where the provider has a model of
  # the same id, else its first, else Another model; with the Thinking tier's effort where
  # that model has it.
  defp new_row(socket, %Connection{} = provider) do
    models = models_of(socket.assigns.providers, provider)
    thinking = socket.assigns.tiers["thinking"] || %{}
    same = Enum.find(models, &(&1.id == thinking["model"]))

    case same || List.first(models) do
      nil ->
        %{
          "provider" => provider.public_id,
          "model" => option(provider, nil),
          "other" => "",
          "effort" => ""
        }

      model ->
        effort = if thinking["effort"] in model.effort, do: thinking["effort"], else: ""

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

  # The providers a new row may have: those that serve the chosen runtime and are offered,
  # but the Key's provider and those of the rows but `except`.
  defp left(assigns, except \\ nil) do
    taken =
      for {row, i} <- Enum.with_index(assigns.fallbacks), i != except, do: row["provider"]

    main = main_provider(assigns)

    for %{provider: provider, offered: true, serves: true} <- assigns.providers,
        provider.public_id not in taken,
        main == nil or provider.id != main.id,
        do: provider
  end

  defp main_provider(%{key: %{provider: provider}}), do: provider
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

  # The form of Runtime and Key, with `errors`, those of `ModelTiers.field_errors/2`: each
  # on Runtime or Key, the tiers' as `tier_errors`.
  defp assign_form(socket, params, errors) do
    {tier_errors, field_errors} =
      Enum.split_with(errors, fn {field, _error} -> field == :tiers or is_tuple(field) end)

    params =
      params
      |> Map.take(["runtime", "key"])
      |> Map.put("runtime", socket.assigns.runtime.name)
      |> Map.put("key", (socket.assigns.key && socket.assigns.key.value) || "")

    assign(socket,
      form: to_form(params, as: :model_choice, errors: field_errors),
      tier_errors: tier_errors
    )
  end

  # The key, the runtime and the tiers as the form sent them. A key the page does not
  # list keeps the key the page had, else the first key. The runtime is the one sent
  # while the key's provider serves it, else the first it serves, so a change of Key keeps
  # the runtime where the new provider serves it. A change of the runtime keeps the
  # models, and an effort the new runtime does not accept goes back to Not set
  # (`ApiaryWeb.ModelTiers.accepted/2`).
  defp take_sent(socket, params) do
    %{keys: keys, key: before, tiers: old, stored: stored} = socket.assigns
    sent = if is_binary(params["key"]), do: ModelTiers.find(keys, params["key"])
    before = before && ModelTiers.find(keys, before.value)
    key = sent || before || List.first(keys)

    name =
      if is_binary(params["runtime"]),
        do: params["runtime"],
        else: socket.assigns.runtime.name

    socket = socket |> assign_providers(name) |> settle(key, name)
    key = key && ModelTiers.find(socket.assigns.keys, key.value)
    stored = ModelTiers.accepted(stored, socket.assigns.runtime)
    tiers = ModelTiers.sent(key, before, old, params["tiers"], stored)

    assign(socket, key: key, tiers: tiers)
  end

  @impl true
  # A change of Key fits the runtime to the key's provider; a change of the runtime
  # fits the tiers' efforts to it (`take_sent/2`).
  def handle_event("choose", %{"model_choice" => params}, socket) do
    socket = socket |> take_sent(params) |> assign_form(params, [])
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
    socket = take_sent(socket, params)
    rows = sent_rows(socket, params)
    socket = assign_fallbacks(socket, rows, %{})

    cond do
      socket.assigns.key == nil ->
        {:noreply, assign_form(socket, params, key: {"is invalid", []})}

      # The saved key, kept while its provider serves no runtime: its line under Key says
      # why, and nothing is written.
      key_line(socket.assigns) != nil ->
        {:noreply, assign_form(socket, params, [])}

      # Save is disabled while a fallback's provider does not serve the runtime: a save
      # sent all the same writes nothing.
      unfit_rows?(socket.assigns) ->
        {:noreply, assign_form(socket, params, [])}

      true ->
        key = socket.assigns.key

        attrs =
          key
          |> ModelTiers.attrs(socket.assigns.tiers)
          |> Map.merge(%{
            runtime: if(Runtimes.several?(), do: socket.assigns.runtime.name),
            fallbacks: fallback_attrs(socket.assigns, rows)
          })
          |> default_key(socket.assigns.choice, key)

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

  # A saved choice that names no key uses its provider's default key, whichever that is
  # (`Apiary.ModelChoices.Resolution`). While Key is still that default, the save names
  # no key either, so the choice keeps following the default.
  defp default_key(attrs, %ModelChoice{connection_id: id, value_id: nil}, %{
         provider: %Connection{id: id, default_value_id: value_id},
         value_id: value_id
       }),
       do: %{attrs | key: nil}

  defp default_key(attrs, _choice, _key), do: attrs

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

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

  # A fallback row's model options: the provider's models, each its title over its id,
  # then its Another model, which a search keeps in view.
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
        ~w(writes fallbacks fallback_errors providers described known key runtime current_scope)a
      )

  attr :page, :map, required: true, doc: "the page's assigns that `fallback_page/1` takes"
  attr :provider, Connection, required: true, doc: "the Key's provider"

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
        unfit: unfit?(page, row),
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
        <div class="grid gap-1">
          <.input
            field={@form[:provider]}
            type="select"
            label={gettext("Provider")}
            options={for provider <- @providers, do: {provider.name, provider.public_id}}
            disabled={!@page.writes}
            aria-describedby={@unfit && "model-fallback-#{@index}-unfit"}
          />
          <p
            :if={@unfit}
            id={"model-fallback-#{@index}-unfit"}
            class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error"
          >
            <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
            {gettext(
              "Choose another provider or remove this fallback. %{provider} does not work with %{runtime}.",
              provider: @page.known[@row["provider"]].name,
              runtime: @page.runtime.title
            )}
          </p>
        </div>
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
          <div id="model-default-head" class="grid gap-1">
            <h2 id="model-default-title" class="q-part-h">{gettext("Default models")}</h2>
            <p id="model-default-line" class="text-[13.5px]/5 text-muted">
              {gettext("Runs use this key and these models when their workflow sets none.")}
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
            :if={@keys != []}
            field={@form[:key]}
            type="choice"
            label={gettext("Key")}
            options={ModelTiers.key_options(@keys)}
            disabled={!@writes}
          />
          <p
            :if={key_line(assigns)}
            id="model-key-unfit"
            class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error"
          >
            <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
            <span><.rich text={key_line(assigns)} /></span>
          </p>
          <ModelTiers.tiers
            :if={@key}
            id="model-tiers"
            name="model_choice[tiers]"
            key={@key}
            tiers={@tiers}
            stored={ModelTiers.accepted(@stored, @runtime)}
            errors={@tier_errors}
            disabled={!@writes}
          />
          <ModelTiers.runtime_part
            :if={@key}
            id="model-runtime"
            select_id="model_choice_runtime"
            name="model_choice[runtime]"
            runtimes={provider_entry(@providers, @key.provider).runtimes}
            runtime={@runtime}
            provider={provider_entry(@providers, @key.provider).title}
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
              :if={@writes and @keys != []}
              id="model-submit"
              type="submit"
              variant="primary"
              disabled={!ModelTiers.complete?(@key, @tiers) or unfit_rows?(assigns)}
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
              "The models runs in %{workspace} use: one key, and a model and an effort for each tier. A workflow can choose another key and models in its settings on the Workflows page. If %{workspace} sets none, its runs use the models of %{organisation}.",
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
