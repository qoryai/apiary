defmodule ApiaryWeb.ProviderLive.Key do
  # A model provider key's Edit key (`:edit`), a separate page of Organisation settings ›
  # Model provider keys, with the features `factory` and `secrets`, of a key by its
  # provider's public id and its row id, which the address has. It shows the key's identity
  # line (`Apiary.ModelKeys.Identity`) as its title, and takes its Name (the value id, which
  # no other key of the provider's kind in the organisation may have), a New value, which
  # keeps the key's value when it is left empty, where New model provider key shows it,
  # Workspaces (`ApiaryWeb.ModelKeyComponents.workspaces_field/1`), and its settings,
  # Resets, Pause for and, for a provider with limit windows, Use up to
  # (`ApiaryWeb.ModelKeyComponents`), written in one transaction
  # (`Apiary.Connections.update_provider_key/4`). Elsewhere the workspaces the key serves
  # show as text, in the same place. A change of the workspaces moves the key to the provider of those
  # workspaces; a move that Remove's rules stop, `{:last_key, place}` or
  # `{:provider_in_use, uses}`, or of a key of a provider that fails its integrity code,
  # shows a sentence above the form on what to do first. Save goes back to the list,
  # which shows that the key is saved.
  #
  # It is for owners and admins (`provider.write`): for anyone else the path is not there,
  # and a save checks the access again. A key of a provider the organisation does not
  # have, or a row id its keys do not have, is not found.
  #
  # For a provider whose keys are logins (`Apiary.ModelKeys.Login`), Edit key has no field
  # for the key: the button Sign in with ChatGPT starts a device sign-in
  # (`ApiaryWeb.ModelKeyDevice`), and Save stores what it made. For a key that needs a new
  # sign-in, the state shows above the button.
  #
  # A key is write-only: the page never renders it nor keeps it in an assign. Its New value
  # field is left out of the page's patches (`phx-update="ignore"`), and each save renders a
  # new, empty field. The tokens of a sign-in are in the process of the sign-in, never in an
  # assign.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  on_mount {ApiaryWeb.Features, :secrets}
  on_mount {ApiaryWeb.Access, :"connection.read"}

  alias Apiary.{Access, Connections, ModelKeys, Organisations}
  alias Apiary.Connections.Connection
  alias Apiary.ModelKeys.{Identity, Login, Setting}
  alias Apiary.Secrets.Value
  alias ApiaryWeb.IntegrationLive.Common
  alias ApiaryWeb.ProviderLive.Index
  alias ApiaryWeb.{ModelKeyComponents, ModelKeyDevice, SettingsComponents, UserAuth}

  # The fields the form sends, each a string, and the workspace ids a list of strings.
  @fields ["name", "key", "reach", "workspace_ids" | ModelKeyComponents.fields()]

  @impl true
  def mount(%{"provider_id" => public_id} = params, _session, socket) do
    scope = socket.assigns.current_scope

    with true <- Access.can?(scope, :"provider.write", scope.organisation),
         {:ok, provider} <- Connections.get_provider(scope, public_id),
         {:ok, key} <- key_of(provider, params) do
      subscription = ModelKeyComponents.subscription?(provider)
      setting = ModelKeys.setting(key.id)
      login? = Login.provider?(provider)
      rejection = ModelKeys.rejections(provider)[key.id]
      workspaces = Organisations.list_workspaces(scope)

      {:ok,
       socket
       |> ModelKeyDevice.attach(login? && provider.provider_kind)
       |> assign(
         provider: provider,
         key: key,
         subscription: subscription,
         login: login?,
         sign_in: login? && sign_in_needed(provider, key, rejection),
         new_key: ModelKeyComponents.new_key(rejection, provider),
         identity: Identity.of(provider, key, Login.by_key(provider)),
         workspaces: workspaces,
         workspaces_words: workspaces_words(workspaces, provider),
         choose_workspaces: Apiary.Edition.scope_setting?(scope) and length(workspaces) > 1,
         limit_windows: ModelKeys.limit_windows(provider),
         sections: SettingsComponents.sections(scope, :organisation),
         attempt: 0,
         refusal: nil,
         page_title:
           SettingsComponents.page_title(scope, :organisation, [
             gettext("Edit key"),
             gettext("Model provider keys")
           ])
       )
       |> assign_form(
         setting
         |> ModelKeyComponents.params(scope, subscription)
         |> Map.merge(%{
           "name" => key.value_id,
           "reach" => if(provider.applies_to == "all", do: "all", else: "selected"),
           "workspace_ids" => Connections.workspace_ids_of(provider)
         }),
         [],
         %{}
       )}
    else
      _not_there -> raise ApiaryWeb.NotFound
    end
  end

  # The key's state when it needs a new sign-in, as the list of keys shows it; else nil.
  # The refresh's verdict comes first, then a rejection by the provider that a run reported.
  defp sign_in_needed(provider, key, rejection) do
    login = ModelKeyComponents.login(Map.get(Login.by_key(provider), key.id), provider)
    rejected = ModelKeyComponents.new_key(rejection, provider)

    cond do
      ModelKeyComponents.sign_in_needed?(login) -> login
      ModelKeyComponents.sign_in_needed?(rejected) -> rejected
      true -> nil
    end
  end

  defp key_of(provider, %{"key_id" => key_id}) do
    with {:ok, row_id} <- Ecto.UUID.cast(key_id),
         %Value{} = key <- Enum.find(provider.secret.values, &(&1.id == row_id)) do
      {:ok, key}
    else
      _not_there -> {:error, :not_found}
    end
  end

  # The workspaces the key serves, in the words of the list of keys.
  defp workspaces_words(workspaces, provider) do
    names = Map.new(workspaces, &{&1.id, &1.name})

    provider
    |> ModelKeyComponents.workspace_names(names)
    |> ModelKeyComponents.workspaces_words()
  end

  # The form, from what was sent but the key, with `errors` on its Key and
  # `settings_errors` on Resets, Pause for and Use up to; the key's field is always empty.
  defp assign_form(socket, params, errors, settings_errors) do
    params =
      params
      |> Map.take(@fields)
      |> Map.put("key", "")
      |> Map.update("workspace_ids", [], &ticked/1)

    assign(socket,
      form: to_form(params, as: :key, errors: errors, action: if(errors != [], do: :validate)),
      settings_errors: settings_errors
    )
  end

  # The workspace ids ticked, without the empty value that keeps the field in the form.
  defp ticked(ids), do: ids |> List.wrap() |> Enum.filter(&(is_binary(&1) and &1 != ""))

  defp list_path(scope), do: ~p"/#{scope.organisation}/settings/model-providers"

  ## Events

  # An event whose fields are not each a string, or a list of strings for the workspaces,
  # is dropped before it is read: the page stays up, so no crash report prints the event,
  # and a key in it. A change shows the form as sent, for Workspaces' list of checkboxes.
  @impl true
  def handle_event(event, %{"key" => %{} = params}, socket) when event in ~w(change save) do
    case {event, sent?(params)} do
      {_event, false} -> {:noreply, socket}
      {"change", true} -> {:noreply, assign_form(socket, params, [], %{})}
      {"save", true} -> save(socket, Map.take(params, @fields))
    end
  end

  def handle_event(event, _params, socket) when event in ~w(change save),
    do: {:noreply, socket}

  defp sent?(params) do
    Enum.all?(@fields, fn
      "workspace_ids" ->
        ids = Map.get(params, "workspace_ids", [])
        is_list(ids) and Enum.all?(ids, &is_binary/1)

      field ->
        is_binary(Map.get(params, field, ""))
    end)
  end

  defp save(socket, params) do
    socket = assign(socket, attempt: socket.assigns.attempt + 1, refusal: nil)

    # Settings that cannot be saved write nothing; the New value is checked with them, so
    # every error shows at once.
    case ModelKeyComponents.read_settings(params, socket.assigns.limit_windows) do
      {:ok, settings} ->
        case input_errors(params, socket.assigns.login, signed_in?(socket)) do
          [] -> update_key(socket, params, settings)
          errors -> {:noreply, assign_form(socket, params, errors, %{})}
        end

      {:error, settings_errors} ->
        {:noreply,
         assign_form(
           socket,
           params,
           input_errors(params, socket.assigns.login, signed_in?(socket)),
           settings_errors
         )}
    end
  end

  # Name, which a save needs, and the New value as `Apiary.Connections` checks it: without
  # the whitespace at its ends. An empty New value keeps the key's value. For a provider
  # whose keys are logins, the value is the sign-in, once the person has signed in
  # (`signed_in`).
  defp input_errors(params, login, signed_in) do
    name =
      if blank?(params["name"]),
        do: [name: {"can't be blank", [validation: :required]}],
        else: []

    value =
      cond do
        login and signed_in ->
          []

        blank?(params["key"]) ->
          []

        true ->
          %Value{}
          |> Value.changeset(%{"value" => Connections.trim_key(params["key"])})
          |> key_errors()
      end

    name ++ value
  end

  # A New value that is empty or only whitespace keeps the key's value; an event without
  # the field has none.
  defp blank?(value), do: String.trim(value || "") == ""

  defp signed_in?(socket), do: ModelKeyDevice.login(socket) != :error

  defp update_key(socket, params, settings) do
    %{current_scope: scope, provider: provider, key: key} = socket.assigns

    attrs =
      Map.merge(reach(socket.assigns, params), %{
        "value_id" => params["name"],
        "value" => ModelKeyDevice.value(socket, socket.assigns.login, params["key"]),
        "settings" => settings
      })

    case Connections.update_provider_key(scope, provider, key.value_id, attrs) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{identity} is saved.", identity: saved_line(socket.assigns, saved, params))
         )
         |> push_navigate(to: list_path(scope))}

      {:error, reason} ->
        refused(socket, params, reason)
    end
  end

  # The workspaces the form chose, where it shows Workspaces; else none, and the key stays
  # where it is. A save of the provider's workspaces moves nothing
  # (`Apiary.Connections.update_provider_key/4`).
  defp reach(%{choose_workspaces: true}, params) do
    if params["reach"] == "all",
      do: %{"applies_to" => "all"},
      else: %{"applies_to" => "selected", "workspace_ids" => ticked(params["workspace_ids"])}
  end

  defp reach(_assigns, _params), do: %{}

  # The identity line of the saved key: by its row id where it stayed, by its value id in
  # the provider it moved to.
  defp saved_line(%{provider: %{id: id} = provider, key: key}, %Connection{id: id}, _params),
    do: Identity.for_key(provider, key.id)

  defp saved_line(%{key: key}, %Connection{} = saved, params),
    do: Identity.for_value_id(saved, Value.normalise_value_id(params["name"]) || key.value_id)

  defp refused(socket, params, %Ecto.Changeset{data: %Setting{}} = changeset),
    do: {:noreply, assign_form(socket, params, [], ModelKeyComponents.errors(changeset))}

  defp refused(socket, params, %Ecto.Changeset{} = changeset),
    do: {:noreply, assign_form(socket, params, key_errors(changeset), %{})}

  # A key or a provider deleted meanwhile, or a membership changed: the scope is read
  # again, and a page the person still reaches has the refusal of the provider pages,
  # with the form as sent.
  defp refused(socket, params, :not_found) do
    socket = UserAuth.reload_scope(socket)

    if socket.redirected,
      do: {:noreply, socket},
      else: shown(socket, params, :not_found)
  end

  defp refused(socket, params, :no_workspace),
    do:
      {:noreply,
       assign_form(
         socket,
         params,
         [workspaces: {gettext("Choose at least one workspace."), []}],
         %{}
       )}

  # A move that Remove's rules stop, or of a key of a provider that fails its integrity
  # code: the sentence above the form.
  defp refused(socket, params, {refusal, _detail} = reason)
       when refusal in [:last_key, :provider_in_use, :integrity] do
    sentence = move_refusal(socket.assigns, reason)
    {:noreply, socket |> assign(:refusal, sentence) |> assign_form(params, [], %{})}
  end

  defp refused(socket, params, reason), do: shown(socket, params, reason)

  defp move_refusal(%{current_scope: scope, provider: provider, key: key}, {:last_key, nil}),
    do:
      gettext(
        "Add another key for every workspace in %{organisation}, then change the workspaces of %{key}. The organisation's default model uses %{provider}.",
        key: key.value_id,
        provider: Index.kind_title(provider),
        organisation: scope.organisation.name
      )

  defp move_refusal(%{current_scope: scope, provider: provider, key: key}, {:last_key, place}),
    do:
      gettext(
        "Add another key, or choose another provider in Workspace settings › Model, then change the workspaces of %{key}. It is the last %{provider} key for %{place}.",
        key: key.value_id,
        provider: Index.kind_title(provider),
        place: Index.place_name(scope, place)
      )

  defp move_refusal(%{key: key}, {:provider_in_use, _uses}),
    do:
      gettext("Wait until the runs that use %{key} end, then change its workspaces.",
        key: key.value_id
      )

  defp move_refusal(%{provider: provider}, {:integrity, _public_ids}),
    do:
      gettext(
        "Ask the administrator of this Qory Apiary to check %{provider}: its settings were changed outside Qory Apiary, so its keys cannot move.",
        provider: provider.name
      )

  # The refusal's sentence above the form (`ApiaryWeb.IntegrationLive.Common.refusal/4`).
  defp shown(socket, params, reason) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:refusal, Common.refusal(scope, reason, [], :"provider.write"))
     |> assign_form(params, [], %{})}
  end

  # The errors of a refused key: those of its value id on Name, the others on New value.
  defp key_errors(%Ecto.Changeset{errors: errors}),
    do:
      for(
        {field, {message, opts}} <- errors,
        do: {if(field == :value_id, do: :name, else: :key), {message, opts}}
      )

  @impl true
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
      <:crumb>{gettext("Edit key")}</:crumb>

      <.settings_page section={:model_providers} title={@identity}>
        <.notice :if={@refusal} kind={:error}>
          <span id="key-refusal">{@refusal}</span>
        </.notice>

        <.form
          for={@form}
          id="key-form"
          method="post"
          phx-change="change"
          phx-submit="save"
          class="grid gap-4"
          novalidate
        >
          <.input
            field={@form[:name]}
            id="key-name"
            label={gettext("Name")}
            autocomplete="off"
            spellcheck="false"
          />
          <ModelKeyComponents.sign_in_with_chatgpt
            :if={@login}
            id="key-sign-in"
            device={@device}
            login={@sign_in}
            errors={ModelKeyDevice.errors(@form[:key])}
          />
          <ModelKeyComponents.new_key_state
            :if={match?({:new_key, _line}, @new_key)}
            id="key-new-key"
            state={@new_key}
            provider={@provider}
          />
          <.input
            :if={!@login}
            field={@form[:key]}
            id={"key-value-#{@attempt}"}
            type="password"
            value={nil}
            label={gettext("New value")}
            hint={
              if match?({:new_key, _line}, @new_key),
                do: ModelKeyComponents.new_key_hint(),
                else: gettext("Leave it empty to keep the value.")
            }
            autocomplete="new-password"
            spellcheck="false"
            phx-update="ignore"
          />
          <ModelKeyComponents.workspaces_field
            :if={@choose_workspaces}
            id="key"
            form={@form}
            workspaces={@workspaces}
            organisation={@current_scope.organisation.name}
          />
          <div :if={!@choose_workspaces} id="key-workspaces" class="grid gap-1">
            <p class="text-[13px]/[18px] font-medium">{gettext("Workspaces")}</p>
            <p id="key-workspaces-names" class="text-[13.5px]/5">{@workspaces_words}</p>
          </div>
          <ModelKeyComponents.settings_fields
            form={@form}
            errors={@settings_errors}
            subscription={@subscription}
            limit_windows={@limit_windows}
          />
          <.page_form_foot id="key-save" cancel={list_path(@current_scope)}>
            <.button id="key-submit" variant="primary" type="submit" loading_text={gettext("Saving")}>
              {gettext("Save")}
            </.button>
          </.page_form_foot>
        </.form>
      </.settings_page>
    </Layouts.app>
    """
  end
end
