defmodule ApiaryWeb.ProviderLive.Index do
  # Organisation settings › Model provider keys, with the features `factory` and `secrets`:
  # the organisation's model provider keys (`:index`), one row per key, in the order they
  # were added: Key, its value id (`key-<n>`), a link to Edit key
  # (`ApiaryWeb.ProviderLive.Key`); Provider, the title of its provider's kind; Workspaces,
  # "Every workspace" or the names of the workspaces its provider reaches, the first two
  # and "and 3 more" past three; State, in the words of
  # `ApiaryWeb.ModelKeyComponents.state_line/1`, or Needs a new key, or the key's sign-in
  # for a provider whose keys are logins; then Edit and Remove. Where the table is narrow, a
  # row stacks: the key and its state, then the provider and the workspaces, then Edit and
  # Remove. Remove turns the row into its confirmation, Remove key and Cancel, and removes
  # the key (`Apiary.Connections.remove_key/3`); a refusal shows above the table.
  #
  # New model provider key (`:new`), a separate page, adds one key
  # (`Apiary.Connections.add_key/2`): Provider; an Address for a provider whose description
  # has an address setting, such as LiteLLM; Key; Workspaces, where the edition shows the
  # setting (`c:Apiary.Edition.scope_setting?/1`) and the organisation has two workspaces or
  # more: "Every workspace in <organisation>" or "Only these workspaces", a checkbox per
  # workspace, the scope's workspace ticked first; then Resets, Pause for and Use up to
  # (`ApiaryWeb.ModelKeyComponents.settings_fields/1`). Without Workspaces, the key serves
  # the scope's workspace. `add_key/2` sets the provider that has the key, and its value
  # id; the list shows "key-3 is added." With no workspace in the scope the page shows no
  # form, and a line reads that a workspace comes first. Beside the form, About model
  # provider keys has what a key is for and where to get the chosen provider's key.
  #
  # The paths of the provider's page and of its Add key, which are gone, open the list
  # (`:moved`).
  #
  # Every member reads the list (`connection.read`); owners and admins add and remove keys
  # (`provider.write`), and anyone else sees the list without New model provider key, Edit
  # and Remove, and one line of who adds one; the form's path is not there for them. The
  # context checks the action again.
  #
  # A key is write-only: the page never renders it nor keeps it in an assign. Its field
  # is left out of the page's patches (`phx-update="ignore"`), so a change of the provider
  # keeps what was typed, and each save renders a new, empty field. For a provider whose
  # keys are logins (`Apiary.ModelKeys.Login`) the field is the button Sign in with ChatGPT
  # (`ApiaryWeb.ModelKeyDevice`), and the sign-in is kept with the form until Save; a
  # change of the provider stops it.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  on_mount {ApiaryWeb.Features, :secrets}
  on_mount {ApiaryWeb.Access, :"connection.read"}

  alias Apiary.{Access, Connections, ModelKeys, Organisations}
  alias Apiary.Connections.Connection
  alias Apiary.Kinds.{Provider, Providers}
  alias Apiary.ModelKeys.Login
  alias Apiary.Secrets.Value
  alias ApiaryWeb.IntegrationLive.Common
  alias ApiaryWeb.{ModelKeyComponents, ModelKeyDevice, SettingsComponents, UserAuth}

  # The fields of the form, besides the address settings of the chosen provider.
  @fields ["provider", "key", "reach", "workspace_ids" | ModelKeyComponents.fields()]

  @impl true
  def mount(_params, _session, %{assigns: %{live_action: :moved}} = socket),
    do: {:ok, push_navigate(socket, to: list_path(socket.assigns.current_scope))}

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    writes = Access.can?(scope, :"provider.write", scope.organisation)
    if socket.assigns.live_action == :new and not writes, do: raise(ApiaryWeb.NotFound)

    workspaces = Organisations.list_workspaces(scope)

    socket =
      socket
      |> ModelKeyDevice.attach()
      |> assign(
        sections: SettingsComponents.sections(scope, :organisation),
        writes: writes,
        workspaces: workspaces,
        choose_workspaces: Apiary.Edition.scope_setting?(scope) and length(workspaces) > 1,
        needs_workspace: needs_workspace?(scope),
        attempt: 0,
        refusal: nil,
        confirming: nil,
        remove_refusal: nil
      )
      |> assign_keys()
      |> assign(:page_title, page_title(scope, socket.assigns.live_action))

    {:ok, assign_form(socket, first_params(scope, first_provider()), [], %{})}
  end

  defp page_title(scope, :new),
    do: SettingsComponents.page_title(scope, :organisation, [new_title(), list_title()])

  defp page_title(scope, _index),
    do: SettingsComponents.page_title(scope, :organisation, [list_title()])

  # Whether an add must wait for a workspace: with no workspace in the scope, a key has no
  # workspace to serve.
  defp needs_workspace?(scope), do: is_nil(scope.workspace)

  defp list_title, do: gettext("Model provider keys")
  defp new_title, do: gettext("New model provider key")

  defp first_provider, do: Providers.offered() |> hd() |> Map.fetch!(:name)

  # The form's first fields: the provider, the scope's workspace alone, and the key's
  # settings empty, Pause for in the unit of the provider's keys.
  defp first_params(scope, provider) do
    scope
    |> settings_params(provider)
    |> Map.merge(%{
      "provider" => provider,
      "reach" => "selected",
      "workspace_ids" => List.wrap(scope.workspace && scope.workspace.id)
    })
  end

  defp settings_params(scope, provider),
    do: ModelKeyComponents.params(nil, scope, subscription?(provider))

  defp subscription?(provider),
    do: ModelKeyComponents.subscription?(%Connection{provider_kind: provider})

  # The form of New model provider key, from what was sent but the key, with `errors` on
  # its fields and `settings_errors` on Resets, Pause for and Use up to; the key's field is
  # always empty.
  defp assign_form(socket, params, errors, settings_errors) do
    params =
      params
      |> Map.take(@fields ++ address_names(params["provider"]))
      |> Map.put("key", "")
      |> Map.update("workspace_ids", [], &ticked/1)

    params = Enum.reduce(errors, params, fn {field, _}, p -> Map.put_new(p, "#{field}", "") end)

    chosen = chosen(params["provider"])

    socket
    |> ModelKeyDevice.for_provider(login_kind(chosen))
    |> assign(
      form:
        to_form(params,
          as: :provider,
          errors: errors,
          action: if(errors != [], do: :validate)
        ),
      settings_errors: settings_errors,
      chosen: chosen
    )
  end

  # The workspace ids ticked, without the empty value that keeps the field in the form.
  defp ticked(ids), do: ids |> List.wrap() |> Enum.filter(&(is_binary(&1) and &1 != ""))

  # The keys of the organisation's providers, one row each, in the order they were added.
  defp assign_keys(socket) do
    scope = socket.assigns.current_scope
    {:ok, providers} = Connections.list_providers(scope)
    names = Map.new(socket.assigns.workspaces, &{&1.id, &1.name})
    now = DateTime.utc_now()

    keys =
      providers
      |> Enum.flat_map(&key_rows(&1, names, now))
      |> Enum.sort_by(&{DateTime.to_unix(&1.added, :microsecond), &1.number})

    assign(socket, providers: providers, keys: keys)
  end

  defp key_rows(%Connection{secret: %{values: [_ | _] = values}} = provider, names, now) do
    states = ModelKeys.provider_states(provider, now)
    percents = ModelKeys.use_up_to_percents(provider)
    windows = ModelKeys.limit_windows(provider)
    logins = Login.by_key(provider)
    rejections = ModelKeys.rejections(provider)
    title = kind_title(provider)
    workspaces = ModelKeyComponents.workspace_names(provider, names)

    for %Value{} = key <- values do
      login = ModelKeyComponents.login(Map.get(logins, key.id), provider)
      new_key = ModelKeyComponents.new_key(Map.get(rejections, key.id), provider)
      # A sign-in rejected by the provider shows as a sign-in that needs a new one.
      rejected = if(match?({:sign_in_needed, _}, new_key), do: new_key)

      %{
        id: key.id,
        name: key.value_id,
        number: Value.key_number(key.value_id) || 0,
        added: key.inserted_at,
        provider: provider,
        title: title,
        workspaces: workspaces,
        state:
          ModelKeyComponents.state(
            Map.get(states, key.id, []),
            now,
            Map.get(percents, key.id),
            windows
          ),
        login: if(ModelKeyComponents.sign_in_needed?(login), do: login, else: rejected || login),
        new_key: if(match?({:new_key, _line}, new_key), do: new_key)
      }
    end
  end

  defp key_rows(_provider, _names, _now), do: []

  # The title of the provider's kind in the catalogue, else the provider's name.
  defp kind_title(%Connection{provider_kind: kind, name: name}) do
    case Providers.fetch(kind) do
      {:ok, %Provider{title: title}} -> title
      :error -> name
    end
  end

  # The sentence of Remove's confirmation: which runs stop using the key.
  defp remove_words(:all), do: gettext("Runs in every workspace stop using it.")

  defp remove_words(names),
    do:
      gettext("Runs in %{workspaces} stop using it.",
        workspaces: ModelKeyComponents.workspaces_words(names)
      )

  @doc false
  # login?/1 is whether the keys of `chosen`, a catalogue provider or nil, are logins
  # (`Apiary.ModelKeys.Login`): the form has the button Sign in with ChatGPT in place of the
  # Key field. The set-up's Model step
  # calls it too.
  def login?(%Provider{name: name}), do: Apiary.ModelKeys.Login.provider?(name)
  def login?(_chosen), do: false

  @doc false
  # login_kind/1 is the catalogue name of `chosen` when its keys are logins, else nil: what
  # `ApiaryWeb.ModelKeyDevice.for_provider/2` takes. The set-up's Model step calls it too.
  def login_kind(chosen), do: if(login?(chosen), do: chosen.name)

  defp chosen(name) do
    case Providers.fetch(name) do
      {:ok, provider} -> provider
      :error -> nil
    end
  end

  @doc false
  # address_names/1 is the address settings of the catalogue's provider whose name is
  # `name`, none for one not in the catalogue. The set-up's Model step calls it too
  # (`ApiaryWeb.WorkspaceSetupLive`), as it calls `field_errors/1`, `setting_title/2`,
  # `get_key/1` and `provider_options/0`.
  def address_names(name) do
    case chosen(name) do
      %Provider{} = provider -> Provider.address_settings(provider)
      nil -> []
    end
  end

  ## Events

  # An event whose fields are not each a string, or a list of strings for the workspaces,
  # is dropped before it is read: the page stays up, so no crash report prints the event,
  # and a key in it.
  @impl true
  def handle_event(event, %{"provider" => %{} = params}, %{assigns: %{writes: true}} = socket)
      when event in ~w(choose create) do
    if sent?(params),
      do: form_event(event, params, socket),
      else: {:noreply, socket}
  end

  def handle_event("remove", %{"id" => id}, %{assigns: %{writes: true}} = socket)
      when is_binary(id) do
    confirming = if Enum.any?(socket.assigns.keys, &(&1.id == id)), do: "key-#{id}"
    {:noreply, assign(socket, confirming: confirming, remove_refusal: nil)}
  end

  def handle_event("cancel_remove", _params, socket),
    do: {:noreply, assign(socket, :confirming, nil)}

  def handle_event("remove_key", %{"id" => id}, %{assigns: %{writes: true}} = socket)
      when is_binary(id) do
    case Enum.find(socket.assigns.keys, &(&1.id == id)) do
      nil -> {:noreply, socket |> assign(confirming: nil) |> assign_keys()}
      key -> remove_key(socket, key)
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp sent?(params) do
    Enum.all?(params, fn
      {field, ids} when field in ~w(workspace_ids _unused_workspace_ids) ->
        is_list(ids) and Enum.all?(ids, &is_binary/1)

      {_field, value} ->
        is_binary(value)
    end)
  end

  # A change of the provider gives the key's settings the unit of the new provider's keys
  # where Pause for is empty.
  defp form_event("choose", params, socket) do
    params =
      if params["provider"] != socket.assigns.form.params["provider"] and
           blank?(params["pause_number"]),
         do:
           Map.merge(
             params,
             Map.take(settings_params(socket.assigns.current_scope, params["provider"]), [
               "pause_unit"
             ])
           ),
         else: params

    {:noreply, assign_form(socket, params, [], %{})}
  end

  defp form_event("create", _params, %{assigns: %{needs_workspace: true}} = socket),
    do: {:noreply, socket}

  defp form_event("create", params, socket) do
    socket = assign(socket, attempt: socket.assigns.attempt + 1, refusal: nil)

    # Settings that cannot be saved write nothing; the Key, or the sign-in, is checked with
    # them, so every error shows at once.
    case ModelKeyComponents.read_settings(params, ModelKeys.limit_windows(params["provider"])) do
      {:ok, key_settings} ->
        create(socket, params, key_settings)

      {:error, settings_errors} ->
        {:noreply, assign_form(socket, params, key_errors(socket, params), settings_errors)}
    end
  end

  # The errors of the Key, or of the sign-in, as `Apiary.Connections.add_key/2` checks it.
  defp key_errors(socket, params) do
    value = ModelKeyDevice.value(socket, login?(socket.assigns.chosen), params["key"])

    %Value{}
    |> Value.changeset(%{"value" => Connections.trim_key(value)})
    |> field_errors()
  end

  defp blank?(value), do: String.trim(value || "") == ""

  defp create(socket, params, key_settings) do
    scope = socket.assigns.current_scope

    attrs =
      Map.merge(reach(socket.assigns, params), %{
        "provider" => params["provider"],
        "value" => ModelKeyDevice.value(socket, login?(socket.assigns.chosen), params["key"]),
        "settings" => Map.new(address_names(params["provider"]), &{&1, params[&1] || ""}),
        "key_settings" => key_settings
      })

    case Connections.add_key(scope, attrs) do
      {:ok, _provider, value_id} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is added.", name: value_id))
         |> push_navigate(to: list_path(scope))}

      {:error, %Ecto.Changeset{data: %Apiary.ModelKeys.Setting{}} = changeset} ->
        {:noreply, assign_form(socket, params, [], ModelKeyComponents.errors(changeset))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, params, field_errors(changeset), %{})}

      {:error, :provider_unknown} ->
        {:noreply, assign_form(socket, params, [provider: {"is invalid", []}], %{})}

      {:error, :no_workspace} ->
        {:noreply,
         assign_form(
           socket,
           params,
           [workspaces: {gettext("Choose at least one workspace."), []}],
           %{}
         )}

      {:error, :not_found} ->
        {:noreply, UserAuth.reload_scope(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:refusal, Common.refusal(scope, reason, [], :"provider.write"))
         |> assign_form(params, [], %{})}
    end
  end

  # The workspaces the key serves: those the form chose where it shows Workspaces, else the
  # scope's workspace.
  defp reach(%{choose_workspaces: true}, %{"reach" => "all"}), do: %{"applies_to" => "all"}

  defp reach(%{choose_workspaces: true}, params),
    do: %{"applies_to" => "selected", "workspace_ids" => ticked(params["workspace_ids"])}

  defp reach(%{current_scope: scope}, _params),
    do: %{"applies_to" => "selected", "workspace_ids" => [scope.workspace.id]}

  defp remove_key(socket, key) do
    scope = socket.assigns.current_scope

    case Connections.remove_key(scope, key.provider, key.id) do
      {:ok, _provider} ->
        {:noreply, socket |> assign(confirming: nil, remove_refusal: nil) |> assign_keys()}

      {:error, :not_found} ->
        {:noreply, socket |> assign(confirming: nil) |> UserAuth.reload_scope() |> assign_keys()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirming: nil, remove_refusal: remove_refusal(scope, key, reason))
         |> assign_keys()}
    end
  end

  # Why a key was not removed, in a sentence.
  defp remove_refusal(scope, key, {:last_key, nil}),
    do:
      gettext(
        "Add another key for every workspace in %{organisation}, then remove %{key}. The organisation's default model uses %{provider}.",
        key: key.name,
        provider: key.title,
        organisation: scope.organisation.name
      )

  defp remove_refusal(scope, key, {:last_key, workspace_id}) do
    place =
      case Enum.find(Organisations.list_workspaces(scope), &(&1.id == workspace_id)) do
        %{name: name} -> name
        nil -> scope.organisation.name
      end

    gettext(
      "Add another key, or choose another provider in Workspace settings › Model, then remove %{key}. It is the last %{provider} key for %{place}.",
      key: key.name,
      provider: key.title,
      place: place
    )
  end

  defp remove_refusal(_scope, key, {:provider_in_use, _uses}),
    do: gettext("Wait until the runs that use %{key} end, then remove it.", key: key.name)

  defp remove_refusal(scope, _key, reason),
    do: Common.refusal(scope, reason, [], :"provider.write")

  @doc false
  # field_errors/1 is the errors of a refused key, each on the field it is about: the
  # keys' secret's and the key's on Key, the settings' on the first address field.
  def field_errors(%Ecto.Changeset{data: %Apiary.Secrets.Secret{}} = changeset) do
    nested =
      for %Ecto.Changeset{errors: errors} <- List.wrap(changeset.changes[:values]),
          {_field, error} <- errors,
          do: {:key, error}

    nested ++ for {_field, error} <- changeset.errors, do: {:key, error}
  end

  def field_errors(%Ecto.Changeset{data: %Value{}} = changeset),
    do: for({_field, error} <- changeset.errors, do: {:key, error})

  def field_errors(%Ecto.Changeset{errors: errors} = changeset) do
    address =
      case address_names(Ecto.Changeset.get_field(changeset, :provider_kind)) do
        [name | _rest] -> String.to_atom(name)
        [] -> :provider
      end

    for {field, error} <- errors,
        do: {if(field == :settings, do: address, else: :provider), error}
  end

  defp list_path(scope), do: ~p"/#{scope.organisation}/settings/model-providers"
  defp new_path(scope), do: ~p"/#{scope.organisation}/settings/model-providers/new"

  defp edit_path(scope, key),
    do:
      ~p"/#{scope.organisation}/settings/model-providers/#{key.provider.public_id}/keys/#{key.id}/edit"

  # Who adds a model provider key, to a person who may not.
  defp who_adds(scope) do
    if Access.reader(scope),
      do: ApiaryWeb.Access.reads_only(scope),
      else:
        ApiaryWeb.Access.who_may(
          scope,
          :"provider.write",
          gettext("Only owners and admins add model provider keys.")
        )
  end

  @doc false
  def setting_title(%Provider{description: description}, name) do
    case get_in(description.document, ["settings", "properties", name, "title"]) do
      title when is_binary(title) -> title
      _none -> name
    end
  end

  @impl true
  def render(%{live_action: :new} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:organisation}
      sections={@sections}
      section={:model_providers}
    >
      <:crumb>{new_title()}</:crumb>

      <.settings_page section={:model_providers} title={new_title()}>
        <.notice :if={@refusal} kind={:error}>
          <span id="new-provider-refusal">{@refusal}</span>
        </.notice>

        <p :if={@needs_workspace} id="new-provider-needs-workspace" class="text-[13.5px]/5">
          <.rich text={
            rich_gettext("%{set_up} first, then add a model provider key in its Model step.",
              set_up: {:link, ~p"/#{@current_scope.organisation}", gettext("Set up a workspace")}
            )
          } />
        </p>

        <.form
          :if={!@needs_workspace}
          for={@form}
          id="new-provider-form"
          method="post"
          phx-change="choose"
          phx-submit="create"
          class="grid gap-4"
          novalidate
        >
          <.input
            field={@form[:provider]}
            type="choice"
            label={gettext("Provider")}
            options={provider_options()}
          />
          <.input
            :for={name <- (@chosen && Provider.address_settings(@chosen)) || []}
            field={@form[String.to_atom(name)]}
            id={"new-provider-#{name}"}
            type="text"
            inputmode="url"
            label={setting_title(@chosen, name)}
            placeholder="https://litellm.example.com"
            hint={gettext("The proxy's https address without /v1.")}
            autocomplete="off"
            spellcheck="false"
            required
          />
          <ModelKeyComponents.sign_in_with_chatgpt
            :if={login?(@chosen)}
            id="new-provider-sign-in"
            device={@device}
            errors={ModelKeyDevice.errors(@form[:key])}
          />
          <.input
            :if={!login?(@chosen)}
            field={@form[:key]}
            id={"new-provider-key-#{@attempt}"}
            type="password"
            value={nil}
            label={gettext("Key")}
            hint={gettext("Qory Apiary stores the key encrypted, and nobody can view it again.")}
            autocomplete="new-password"
            spellcheck="false"
            phx-update="ignore"
            required
          />
          <.workspaces_field
            :if={@choose_workspaces}
            form={@form}
            workspaces={@workspaces}
            organisation={@current_scope.organisation.name}
          />
          <ModelKeyComponents.settings_fields
            form={@form}
            errors={@settings_errors}
            subscription={subscription?(@form[:provider].value)}
            limit_windows={ModelKeys.limit_windows(@form[:provider].value)}
          />
          <.page_form_foot id="new-provider-save" cancel={list_path(@current_scope)}>
            <.button
              id="new-provider-submit"
              variant="primary"
              type="submit"
              loading_text={gettext("Saving")}
            >
              {gettext("Save")}
            </.button>
          </.page_form_foot>
        </.form>
        <:context about={gettext("About model provider keys")}>
          <.context
            organisation={@current_scope.organisation}
            workspace={@current_scope.workspace}
            chosen={@chosen}
          />
        </:context>
      </.settings_page>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:organisation}
      sections={@sections}
      section={:model_providers}
    >
      <.settings_page section={:model_providers} title={list_title()} measure="list">
        <:actions :if={@writes}>
          <.button id="new-model-provider" variant="primary" navigate={new_path(@current_scope)}>
            {new_title()}
          </.button>
        </:actions>

        <.notice :if={@remove_refusal} kind={:error}>
          <span id="keys-refusal">{@remove_refusal}</span>
        </.notice>

        <.empty_state
          :if={@keys == []}
          icon={nil}
          tone="neutral"
          title={gettext("No model provider key yet")}
        >
          <p id="providers-none">{gettext("Add a model provider key, so agents can run.")}</p>
        </.empty_state>

        <.table
          :if={@keys != []}
          id="providers"
          label={list_title()}
          rows={@keys}
          row_id={&"key-#{&1.id}"}
          confirming={@confirming}
        >
          <:col :let={key} label={gettext("Key")} kind="title">
            <div class="flex items-baseline gap-2">
              <.link
                :if={@writes}
                id={"key-#{key.id}-name"}
                navigate={edit_path(@current_scope, key)}
                class="font-mono text-[12.5px] hover:underline"
              >
                {key.name}
              </.link>
              <span :if={!@writes} id={"key-#{key.id}-name"} class="font-mono text-[12.5px]">
                {key.name}
              </span>
              <span class="q-to-sm"><.key_state id={"key-#{key.id}-narrow"} key={key} /></span>
            </div>
            <div class="q-to-sm text-[13px]/5 text-muted">
              {key.title} · {ModelKeyComponents.workspaces_words(key.workspaces)}
            </div>
            <div :if={@writes} class="q-to-sm mt-1 text-[13px]/5">
              <.key_actions id={"key-#{key.id}-narrow"} key={key} scope={@current_scope} />
            </div>
          </:col>
          <:col :let={key} label={gettext("Provider")} from="sm">
            <span id={"key-#{key.id}-provider"}>{key.title}</span>
          </:col>
          <:col :let={key} label={gettext("Workspaces")} from="sm">
            <span id={"key-#{key.id}-workspaces"} class="text-muted">
              {ModelKeyComponents.workspaces_words(key.workspaces)}
            </span>
          </:col>
          <:col :let={key} label={gettext("State")} from="sm">
            <.key_state id={"key-#{key.id}"} key={key} />
          </:col>
          <:col :let={key} :if={@writes} label="" from="sm">
            <div class="text-right whitespace-nowrap text-[13px]">
              <.key_actions id={"key-#{key.id}"} key={key} scope={@current_scope} />
            </div>
          </:col>
          <:confirm :let={key}>
            <.inline_confirm
              id={"key-#{key.id}-confirm"}
              question={gettext("Remove %{key}?", key: key.name)}
              cancel={JS.push("cancel_remove")}
            >
              {remove_words(key.workspaces)}
              <:action>
                <.button
                  id={"key-#{key.id}-remove-confirm"}
                  variant="danger"
                  size="xs"
                  phx-click="remove_key"
                  phx-value-id={key.id}
                  loading_text={gettext("Removing")}
                >
                  {gettext("Remove key")}
                </.button>
              </:action>
            </.inline_confirm>
          </:confirm>
        </.table>

        <p :if={!@writes} id="providers-who" class="q-foot-note">{who_adds(@current_scope)}</p>
      </.settings_page>
    </Layouts.app>
    """
  end

  # A key's state: Needs a new sign-in or Needs a new key in place of its state, and the
  # sign-in of a login under it.
  attr :id, :string, required: true
  attr :key, :map, required: true

  defp key_state(assigns) do
    ~H"""
    <ModelKeyComponents.state_line
      :if={!ModelKeyComponents.sign_in_needed?(@key.login) and !@key.new_key}
      id={"#{@id}-state"}
      state={@key.state}
    />
    <ModelKeyComponents.new_key_state
      :if={@key.new_key}
      id={"#{@id}-new-key"}
      state={@key.new_key}
      provider={@key.provider}
    />
    <ModelKeyComponents.login_line :if={@key.login} id={"#{@id}-login"} login={@key.login} />
    """
  end

  # Edit and Remove of a key's row.
  attr :id, :string, required: true
  attr :key, :map, required: true
  attr :scope, :any, required: true

  defp key_actions(assigns) do
    ~H"""
    <.link
      id={"#{@id}-edit"}
      navigate={edit_path(@scope, @key)}
      class="hover:underline"
      aria-label={gettext("Edit %{key}", key: @key.name)}
    >
      {gettext("Edit")}
    </.link>
    <span class="text-muted" aria-hidden="true">&nbsp;·&nbsp;</span>
    <button
      id={"#{@id}-remove"}
      type="button"
      class="cursor-pointer hover:underline"
      phx-click="remove"
      phx-value-id={@key.id}
      aria-label={gettext("Remove %{key}", key: @key.name)}
    >
      {gettext("Remove")}
    </button>
    """
  end

  # Workspaces: every workspace of the organisation, or only those ticked, a checkbox per
  # workspace under the second choice. While every workspace is chosen, the ticks are kept
  # in hidden fields.
  attr :form, Phoenix.HTML.Form, required: true
  attr :workspaces, :list, required: true
  attr :organisation, :string, required: true

  defp workspaces_field(assigns) do
    assigns =
      assign(assigns,
        only: assigns.form[:reach].value != "all",
        ticked: List.wrap(assigns.form[:workspace_ids].value),
        errors: Enum.map(assigns.form[:workspaces].errors, &translate_error/1)
      )

    ~H"""
    <fieldset
      id="new-provider-workspaces"
      class="fieldset"
      aria-invalid={@errors != [] && "true"}
      aria-describedby={@errors != [] && "new-provider-workspaces-error"}
    >
      <legend class="mb-1 text-[13px]/[18px] font-medium">{gettext("Workspaces")}</legend>
      <input type="hidden" name="provider[workspace_ids][]" value="" />
      <label
        for="new-provider-reach-all"
        class="inline-flex w-fit cursor-pointer items-center gap-2 text-[13.5px]/5 max-md:min-h-10"
      >
        <input
          type="radio"
          id="new-provider-reach-all"
          name="provider[reach]"
          value="all"
          checked={!@only}
          class="radio radio-sm radio-primary"
        />
        {gettext("Every workspace in %{organisation}", organisation: @organisation)}
      </label>
      <label
        for="new-provider-reach-selected"
        class="inline-flex w-fit cursor-pointer items-center gap-2 text-[13.5px]/5 max-md:min-h-10"
      >
        <input
          type="radio"
          id="new-provider-reach-selected"
          name="provider[reach]"
          value="selected"
          checked={@only}
          class="radio radio-sm radio-primary"
        />
        {gettext("Only these workspaces")}
      </label>
      <div :if={@only} id="new-provider-workspace-list" class="grid gap-1 pl-6">
        <label
          :for={workspace <- @workspaces}
          for={"new-provider-workspace-#{workspace.id}"}
          class="inline-flex w-fit cursor-pointer items-center gap-2 text-[13.5px]/5 max-md:min-h-10"
        >
          <input
            type="checkbox"
            id={"new-provider-workspace-#{workspace.id}"}
            name="provider[workspace_ids][]"
            value={workspace.id}
            checked={workspace.id in @ticked}
            class="checkbox checkbox-sm checkbox-primary"
          />
          {workspace.name}
        </label>
      </div>
      <input
        :for={id <- @ticked}
        :if={!@only}
        type="hidden"
        name="provider[workspace_ids][]"
        value={id}
      />
      <p
        :for={msg <- @errors}
        id="new-provider-workspaces-error"
        class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error"
      >
        <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
        {msg}
      </p>
    </fieldset>
    """
  end

  # The context of New model provider: what a key is for, where to get the chosen
  # provider's key, and the model to choose next. The last sentence names the workspace the
  # reader is in, and is left out without one.
  attr :organisation, :any, required: true
  attr :workspace, :any, required: true
  attr :chosen, :any, required: true

  defp context(assigns) do
    ~H"""
    <p id="new-provider-what">
      {gettext("A model provider's key lets runs in %{organisation} call a model.",
        organisation: @organisation.name
      )}
    </p>
    <.get_key id="new-provider-get-key" chosen={@chosen} />
    <p :if={@workspace} id="new-provider-next">
      {gettext("After you save, choose the model for %{workspace} in Workspace settings › Model.",
        workspace: @workspace.name
      )}
    </p>
    """
  end

  @doc false
  # get_key/1 is where to get the key of the chosen provider, nothing for one not in this
  # list. For the Claude subscription it is two sentences with the command between them,
  # on a line with Copy (`ApiaryWeb.CoreComponents.command_line/1`).
  attr :id, :string, required: true
  attr :chosen, :any, required: true

  def get_key(%{chosen: %Provider{name: "claude-subscription"}} = assigns) do
    ~H"""
    <div id={@id} class="grid gap-2.5">
      <p id={"#{@id}-run"}>
        {gettext(
          "Get the key from the provider first. In a terminal where Claude Code is installed, run:"
        )}
      </p>
      <.command_line id={"#{@id}-command"} command="claude setup-token" />
      <p id={"#{@id}-copy-token"}>
        <.rich text={
          rich_gettext("Then copy the token it prints. %{terms} allow this for personal use only.",
            terms: {:part, :terms}
          )
        }>
          <:part name={:terms}>
            <.terms href={terms_url(@chosen)} vendor={vendor(@chosen)} />
          </:part>
        </.rich>
      </p>
    </div>
    """
  end

  def get_key(assigns) do
    assigns = assign(assigns, :text, get_key_text(assigns.chosen))

    ~H"""
    <p :if={@text} id={@id}><.rich text={@text} /></p>
    """
  end

  defp get_key_text(%Provider{name: "anthropic"}),
    do: gettext("Get the key from the provider first: create an API key in the Claude Console.")

  defp get_key_text(%Provider{name: "openai"}),
    do: gettext("Get the key from the provider first: create an API key in the OpenAI Platform.")

  defp get_key_text(%Provider{name: "deepseek"}),
    do: gettext("Get the key from the provider first: create a DeepSeek API key.")

  defp get_key_text(%Provider{name: "openrouter"}),
    do: gettext("Get the key from the provider first: create an OpenRouter API key.")

  defp get_key_text(%Provider{name: "litellm"}),
    do:
      rich_gettext(
        "First get a key that your LiteLLM proxy accepts, and the proxy's https address without %{v1}, such as %{example}.",
        v1: {:m, "/v1"},
        example: {:m, "https://litellm.example.com"}
      )

  defp get_key_text(_chosen), do: nil

  # The vendor's terms, such as Anthropic's, a link out to `href`, or plain words where
  # the description has no address.
  @doc false
  attr :href, :string, required: true
  attr :vendor, :string, required: true

  def terms(assigns) do
    ~H"""
    <.external_link :if={@href} href={@href}>{terms_words(@vendor)}</.external_link>
    <span :if={!@href}>{terms_words(@vendor)}</span>
    """
  end

  # A vendor such as "your LiteLLM proxy" starts a line, so its first letter is upper case.
  defp terms_words(vendor),
    do: gettext("%{vendor}'s terms", vendor: upcase_first(vendor))

  defp upcase_first(text) do
    case String.next_grapheme(text) do
      {first, rest} -> String.upcase(first) <> rest
      nil -> text
    end
  end

  # The vendor of the provider's description, which names the company behind the model
  # API, or the provider's title for a description with none.
  defp vendor(%Provider{vendor: vendor}) when is_binary(vendor), do: vendor
  defp vendor(%Provider{title: title}), do: title

  @doc false
  # provider_options/0 is each provider of the catalogue that is offered
  # (`Providers.offered/0`), its description's text under its title. A subtitle is plain
  # text: the description's backticks and the address that ends it, which About model
  # providers links to (`terms_url/1`), are left out.
  def provider_options do
    for provider <- Providers.offered() do
      %{value: provider.name, title: provider.title, subtitle: subtitle(provider)}
    end
  end

  defp subtitle(%Provider{description: %{document: %{"description" => text}}})
       when is_binary(text) do
    text
    |> String.replace(~r{\s*[^.]*:\s*https://\S+\s*$}, "")
    |> String.replace("`", "")
  end

  defp subtitle(_provider), do: nil

  # The address that ends the provider's description, such as the Claude subscription's
  # link to Anthropic's terms, nil without one; a subtitle shows text only, so the link is
  # here.
  @doc false
  def terms_url(%Provider{description: %{document: %{"description" => text}}})
      when is_binary(text) do
    case Regex.run(~r{(https://\S+)\s*$}, text) do
      [_all, url] -> url
      nil -> nil
    end
  end

  def terms_url(_chosen), do: nil
end
