defmodule ApiaryWeb.ProviderLive.Key do
  # A model provider's Add key (`:new`) and Edit key (`:edit`), separate pages of
  # Organisation settings › Model providers › the provider, with the features `factory`
  # and `secrets`. Add key takes the key's Name, the Key and its settings, Resets and
  # Pause for (`ApiaryWeb.ModelKeyComponents`), and writes them in one transaction
  # (`Apiary.Connections.add_provider_key/4`); for a subscription, About model providers
  # has where to get the key and the terms that allow it. Edit key, of a key by its value
  # id, takes its Name and its settings, never its value
  # (`Apiary.Connections.update_provider_key/4`). Each save goes back to the provider's
  # page, which says it.
  #
  # Both are for owners and admins (`provider.write`): for anyone else the paths are not
  # there, and the context asks again. A key of a provider the organisation does not have,
  # or a value id its keys do not have, is not found.
  #
  # A key is write-only: the page never renders it nor keeps it in an assign. Its field
  # is left out of the page's patches (`phx-update="ignore"`), and each save renders a
  # new, empty field.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  on_mount {ApiaryWeb.Features, :secrets}
  on_mount {ApiaryWeb.Access, :"connection.read"}

  alias Apiary.{Access, Connections, ModelKeys, Secrets}
  alias Apiary.Kinds.Providers
  alias Apiary.ModelKeys.Setting
  alias Apiary.Secrets.Value
  alias ApiaryWeb.IntegrationLive.Common
  alias ApiaryWeb.ProviderLive.Index, as: ProviderPage
  alias ApiaryWeb.{ModelKeyComponents, SettingsComponents, UserAuth}

  # The fields the form sends, each a string.
  @fields ["value_id", "key" | ModelKeyComponents.fields()]

  @impl true
  def mount(%{"provider_id" => public_id} = params, _session, socket) do
    scope = socket.assigns.current_scope
    action = socket.assigns.live_action

    with true <- Access.can?(scope, :"provider.write", scope.organisation),
         {:ok, provider} <- Connections.get_provider(scope, public_id),
         {:ok, key} <- key_of(provider, action, params) do
      subscription = ModelKeyComponents.subscription?(provider)
      setting = key && ModelKeys.setting(key.id)

      {:ok,
       socket
       |> assign(
         provider: provider,
         key: key,
         subscription: subscription,
         chosen: chosen(provider, subscription),
         sections: SettingsComponents.sections(scope, :organisation),
         attempt: 0,
         refusal: nil,
         page_title:
           SettingsComponents.page_title(scope, :organisation, [
             crumb(action),
             provider.name,
             gettext("Model providers")
           ])
       )
       |> assign_form(
         Map.merge(
           %{"value_id" => (key && key.value_id) || ""},
           ModelKeyComponents.params(setting, scope, subscription)
         ),
         [],
         %{}
       )}
    else
      _not_there -> raise ApiaryWeb.NotFound
    end
  end

  defp key_of(_provider, :new, _params), do: {:ok, nil}

  defp key_of(provider, :edit, %{"value_id" => value_id}) do
    case Enum.find(provider.secret.values, &(&1.value_id == value_id)) do
      %Value{} = key -> {:ok, key}
      nil -> {:error, :not_found}
    end
  end

  # The catalogue's provider, for where to get a subscription's key; nil for an API key.
  defp chosen(provider, true) do
    case Providers.fetch(provider.provider_kind) do
      {:ok, chosen} -> chosen
      :error -> nil
    end
  end

  defp chosen(_provider, false), do: nil

  # The form, from what was sent but the key, with `errors` on its Name and Key and
  # `settings_errors` on Resets and Pause for; the key's field is always empty.
  defp assign_form(socket, params, errors, settings_errors) do
    params =
      params
      |> Map.take(@fields)
      |> Map.put("key", "")

    assign(socket,
      form: to_form(params, as: :key, errors: errors, action: if(errors != [], do: :validate)),
      settings_errors: settings_errors
    )
  end

  defp crumb(:new), do: gettext("Add key")
  defp crumb(:edit), do: gettext("Edit key")

  defp provider_path(scope, provider),
    do: ~p"/#{scope.organisation}/settings/model-providers/#{provider.public_id}"

  ## Events

  # An event whose fields are not each a string is dropped before it is read: the page
  # stays up, so no crash report prints the event, and a key in it.
  @impl true
  def handle_event("save", %{"key" => %{} = params}, socket) do
    if Enum.all?(@fields, &is_binary(Map.get(params, &1, ""))),
      do: save(socket, socket.assigns.live_action, Map.take(params, @fields)),
      else: {:noreply, socket}
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  defp save(socket, action, params) do
    socket = assign(socket, attempt: socket.assigns.attempt + 1, refusal: nil)

    # Settings that cannot be saved write nothing; the Name and the Key are checked with
    # them, so every error shows at once.
    case ModelKeyComponents.read_settings(params) do
      {:ok, settings} ->
        write(socket, action, params, settings)

      {:error, settings_errors} ->
        {:noreply, assign_form(socket, params, input_errors(action, params), settings_errors)}
    end
  end

  defp input_errors(:new, params) do
    %Value{}
    |> Value.changeset(%{"value_id" => params["value_id"], "value" => params["key"]},
      value_id: :required
    )
    |> key_errors(nil)
  end

  defp input_errors(:edit, params) do
    %Value{}
    |> Ecto.Changeset.cast(%{"value_id" => params["value_id"]}, [:value_id])
    |> Value.value_id_changeset(:required)
    |> key_errors(nil)
  end

  defp write(socket, :new, params, settings) do
    %{current_scope: scope, provider: provider} = socket.assigns
    attrs = %{"value_id" => params["value_id"], "value" => params["key"]}

    case Connections.add_provider_key(scope, provider, attrs, settings) do
      {:ok, _provider} ->
        saved(
          socket,
          gettext("%{name} is added.", name: Value.normalise_value_id(params["value_id"]))
        )

      {:error, reason} ->
        refused(socket, params, reason)
    end
  end

  defp write(socket, :edit, params, settings) do
    %{current_scope: scope, provider: provider, key: key} = socket.assigns
    attrs = %{"value_id" => params["value_id"], "settings" => settings}

    case Connections.update_provider_key(scope, provider, key.value_id, attrs) do
      {:ok, _provider} ->
        saved(
          socket,
          gettext("%{name} is saved.", name: Value.normalise_value_id(params["value_id"]))
        )

      {:error, reason} ->
        refused(socket, params, reason)
    end
  end

  defp saved(socket, words) do
    %{current_scope: scope, provider: provider} = socket.assigns

    {:noreply,
     socket
     |> put_flash(:info, words)
     |> push_navigate(to: provider_path(scope, provider))}
  end

  defp refused(socket, params, %Ecto.Changeset{data: %Setting{}} = changeset),
    do: {:noreply, assign_form(socket, params, [], ModelKeyComponents.errors(changeset))}

  defp refused(socket, params, %Ecto.Changeset{} = changeset),
    do:
      {:noreply, assign_form(socket, params, key_errors(changeset, socket.assigns.provider), %{})}

  defp refused(socket, params, :too_many_values) do
    limit =
      gettext(
        "%{provider} has %{number} keys, the most it can have. Delete a key to add another.",
        provider: socket.assigns.provider.name,
        number: Format.number(Secrets.max_values())
      )

    {:noreply, assign_form(socket, params, [key: {limit, []}], %{})}
  end

  # A key or a provider deleted meanwhile, or a membership changed: the scope is read
  # again, and a page the person still reaches has the refusal of the provider pages,
  # with the form as sent.
  defp refused(socket, params, :not_found) do
    socket = UserAuth.reload_scope(socket)

    if socket.redirected,
      do: {:noreply, socket},
      else: shown(socket, params, :not_found)
  end

  defp refused(socket, params, reason), do: shown(socket, params, reason)

  # The refusal's sentence above the form (`ApiaryWeb.IntegrationLive.Common.refusal/4`).
  defp shown(socket, params, reason) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:refusal, Common.refusal(scope, reason, [], :"provider.write"))
     |> assign_form(params, [], %{})}
  end

  # The errors of a refused key on the form's Name and Key: a value's on Key, the rest on
  # Name, a name another key of the provider has in this page's words.
  defp key_errors(%Ecto.Changeset{errors: errors}, provider) do
    for {field, {message, opts}} <- errors do
      cond do
        field == :value -> {:key, {message, opts}}
        opts[:constraint] == :unique and provider -> {:value_id, taken(provider)}
        true -> {:value_id, {message, opts}}
      end
    end
  end

  defp taken(provider),
    do:
      {dgettext_noop("errors", "Another key of %{provider} has this name."),
       [provider: provider.name]}

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
      <:crumb title={@provider.name} navigate={provider_path(@current_scope, @provider)}>
        {@provider.name}
      </:crumb>
      <:crumb>{crumb(@live_action)}</:crumb>

      <.settings_page section={:model_providers} title={crumb(@live_action)}>
        <.notice :if={@refusal} kind={:error}>
          <span id="key-refusal">{@refusal}</span>
        </.notice>

        <.form
          for={@form}
          id="key-form"
          method="post"
          phx-submit="save"
          class="grid gap-4"
          novalidate
        >
          <.input
            field={@form[:value_id]}
            label={gettext("Name")}
            hint={gettext("Lowercase letters, digits, ., _ and -.")}
            autocomplete="off"
            spellcheck="false"
            class="font-mono"
            required
          />
          <.input
            :if={@live_action == :new}
            field={@form[:key]}
            id={"key-value-#{@attempt}"}
            type="password"
            value={nil}
            label={gettext("Key")}
            hint={gettext("Qory Apiary stores the key encrypted, and nobody can view it again.")}
            autocomplete="off"
            spellcheck="false"
            phx-update="ignore"
            required
          />
          <ModelKeyComponents.settings_fields
            form={@form}
            errors={@settings_errors}
            subscription={@subscription}
          />
          <.page_form_foot id="key-save" cancel={provider_path(@current_scope, @provider)}>
            <.button id="key-submit" variant="primary" type="submit" loading_text={gettext("Saving")}>
              {if @live_action == :new, do: gettext("Add key"), else: gettext("Save")}
            </.button>
          </.page_form_foot>
        </.form>
        <:context :if={@live_action == :new and @chosen} about={gettext("About model providers")}>
          <ProviderPage.get_key id="key-get-key" chosen={@chosen} />
        </:context>
      </.settings_page>
    </Layouts.app>
    """
  end
end
