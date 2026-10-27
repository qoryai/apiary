defmodule ApiaryWeb.ModelChoiceLive do
  # Workspace settings › Model, `/:org/:workspace/settings/model`, with the features
  # `factory` and `secrets`: the workspace's model choice (level 5, `Apiary.ModelChoices`).
  #
  # Runtime, a select of the runtime catalogue (`Apiary.Kinds.Runtimes`), shown only while
  # the catalogue has more than one; with one, the choice names none and its runs use that
  # one (`Apiary.ModelChoices.default_runtime/0`). Model: a select of the models the page
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

    socket
    |> assign(
      applicable: Enum.filter(providers, &applies?(&1, scope.workspace.id)),
      runtimes: Runtimes.list(),
      choice: choice
    )
    |> assign_runtime(runtime)
    |> then(&assign_form(&1, choice_params(choice, &1.assigns.providers), []))
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

    {:noreply, assign_form(socket, params, [])}
  end

  def handle_event("save", %{"model_choice" => params}, %{assigns: %{writes: true}} = socket) do
    scope = socket.assigns.current_scope

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
            effort: effort
          }
          |> Map.merge(kept(socket.assigns.choice, provider))

        case ModelChoices.put_choice(scope, :workspace, attrs) do
          {:ok, _choice} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Model saved."))
             |> load()}

          {:error, %Ecto.Changeset{errors: errors}} ->
            {:noreply, assign_form(socket, params, field_errors(errors, model))}

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

  def handle_event("save", _params, socket), do: {:noreply, socket}

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

  # The select's options: each provider's models, then its Another model, in a group
  # named after the provider where there are several.
  defp options([%{provider: provider, models: models}]), do: provider_options(provider, models)

  defp options(providers),
    do:
      for(%{provider: p, models: models} <- providers, do: {p.name, provider_options(p, models)})

  defp provider_options(provider, models),
    do:
      for(model <- models, do: {model.title, option(provider, model.id)}) ++
        [{gettext("Another model"), option(provider, nil)}]

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
        <:subtitle>
          <span id="model-line">
            {gettext(
              "%{workspace}'s default model. A workflow or a target can set another model for its runs. If %{workspace} sets none, its runs use %{organisation}'s model.",
              workspace: @current_scope.workspace.name,
              organisation: @current_scope.organisation.name
            )}
          </span>
        </:subtitle>

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
            type="select"
            label={gettext("Model")}
            options={options(@providers)}
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
      </SettingsComponents.layout>
    </Layouts.app>
    """
  end
end
