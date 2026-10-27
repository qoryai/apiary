defmodule ApiaryWeb.ProviderLive.Index do
  # Organisation settings › Model providers, with the features `factory` and `secrets`:
  # the list of the organisation's model providers (`:index`), each by its name with how
  # many keys it has, its name leading to its page (`ApiaryWeb.ProviderLive.Show`), and
  # New model provider (`:new`), a separate page that adds one with its key
  # (`Apiary.Connections.create_provider/2`): Provider, Key, and an Address for a
  # provider whose description has an address setting, such as LiteLLM.
  #
  # Every member reads the list (`connection.read`); owners and admins add one
  # (`provider.write`), and anyone else sees the list without New model provider and one
  # line of who adds one; the form's path is not there for them. The context asks again.
  #
  # A key is write-only: the page never renders it nor keeps it in an assign. Its field
  # is left out of the page's patches (`phx-update="ignore"`), so a change of the provider
  # keeps what was typed, and each save renders a new, empty field.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  on_mount {ApiaryWeb.Features, :secrets}
  on_mount {ApiaryWeb.Access, :"connection.read"}

  alias Apiary.{Access, Connections}
  alias Apiary.Kinds.{Provider, Providers}
  alias ApiaryWeb.IntegrationLive.Common
  alias ApiaryWeb.{SettingsComponents, UserAuth}

  # The value id of the key that New model provider adds.
  @key_id "key-1"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    writes = Access.can?(scope, :"provider.write", scope.organisation)
    if socket.assigns.live_action == :new and not writes, do: raise(ApiaryWeb.NotFound)

    {:ok, providers} = Connections.list_providers(scope)

    {:ok,
     socket
     |> assign(
       sections: SettingsComponents.sections(scope, :organisation),
       providers: providers,
       writes: writes,
       attempt: 0,
       refusal: nil
     )
     |> assign_form(%{"provider" => first_provider()}, [])
     |> assign(:page_title, page_title(scope, socket.assigns.live_action))}
  end

  defp page_title(scope, :new),
    do: SettingsComponents.page_title(scope, :organisation, [new_title(), list_title()])

  defp page_title(scope, _index),
    do: SettingsComponents.page_title(scope, :organisation, [list_title()])

  defp list_title, do: gettext("Model providers")
  defp new_title, do: gettext("New model provider")

  defp first_provider, do: Providers.list() |> hd() |> Map.fetch!(:name)

  # The form of New model provider, from what was sent but the key, with `errors` on its
  # fields; the key's field is always empty.
  defp assign_form(socket, params, errors) do
    params =
      params
      |> Map.take(["provider" | address_names(params["provider"])])
      |> Map.put("key", "")

    params = Enum.reduce(errors, params, fn {field, _}, p -> Map.put_new(p, "#{field}", "") end)

    assign(socket,
      form: to_form(params, as: :provider, errors: errors),
      chosen: chosen(params["provider"])
    )
  end

  defp chosen(name) do
    case Providers.fetch(name) do
      {:ok, provider} -> provider
      :error -> nil
    end
  end

  # The address settings of the provider named `name`, none for one not in the catalogue.
  defp address_names(name) do
    case chosen(name) do
      %Provider{} = provider -> Provider.address_settings(provider)
      nil -> []
    end
  end

  @impl true
  def handle_event("choose", %{"provider" => params}, %{assigns: %{writes: true}} = socket),
    do: {:noreply, assign_form(socket, params, [])}

  def handle_event("create", %{"provider" => params}, %{assigns: %{writes: true}} = socket) do
    scope = socket.assigns.current_scope
    socket = assign(socket, attempt: socket.assigns.attempt + 1, refusal: nil)

    attrs = %{
      "provider" => params["provider"],
      "keys" => [%{"value_id" => @key_id, "value" => params["key"] || ""}],
      "settings" => Map.new(address_names(params["provider"]), &{&1, params[&1] || ""})
    }

    case Connections.create_provider(scope, attrs) do
      {:ok, provider} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is added.", name: provider.name))
         |> push_navigate(to: provider_path(scope, provider))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, params, field_errors(changeset))}

      {:error, :provider_unknown} ->
        {:noreply, assign_form(socket, params, provider: {"is invalid", []})}

      {:error, :not_found} ->
        {:noreply, UserAuth.reload_scope(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:refusal, Common.refusal(scope, reason, [], :"provider.write"))
         |> assign_form(params, [])}
    end
  end

  def handle_event(event, _params, socket) when event in ~w(choose create),
    do: {:noreply, socket}

  # The errors of a refused provider, each on the field it is about: the keys' secret's
  # on Key, the settings' on the first address field.
  defp field_errors(%Ecto.Changeset{data: %Apiary.Secrets.Secret{}} = changeset) do
    nested =
      for %Ecto.Changeset{errors: errors} <- List.wrap(changeset.changes[:values]),
          {_field, error} <- errors,
          do: {:key, error}

    nested ++ for {_field, error} <- changeset.errors, do: {:key, error}
  end

  defp field_errors(%Ecto.Changeset{errors: errors} = changeset) do
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

  defp provider_path(scope, provider),
    do: ~p"/#{scope.organisation}/settings/model-providers/#{provider.public_id}"

  defp keys(%{secret: %{values: values}}) when is_list(values), do: length(values)
  defp keys(_provider), do: 0

  # Who adds a model provider, to a person who may not.
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

  defp setting_title(%Provider{description: description}, name) do
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
        <.help workspace={@current_scope.workspace} />

        <.notice :if={@refusal} kind={:error}>
          <span id="new-provider-refusal">{@refusal}</span>
        </.notice>

        <.form
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
            type="select"
            label={gettext("Provider")}
            options={for p <- Providers.list(), do: {p.title, p.name}}
          />
          <.input
            field={@form[:key]}
            id={"new-provider-key-#{@attempt}"}
            type="password"
            value={nil}
            label={gettext("Key")}
            autocomplete="off"
            spellcheck="false"
            phx-update="ignore"
            required
          />
          <.input
            :for={name <- (@chosen && Provider.address_settings(@chosen)) || []}
            field={@form[String.to_atom(name)]}
            id={"new-provider-#{name}"}
            type="text"
            inputmode="url"
            label={setting_title(@chosen, name)}
            placeholder="https://litellm.example.com"
            autocomplete="off"
            spellcheck="false"
            required
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

        <.empty_state
          :if={@providers == []}
          icon={nil}
          tone="neutral"
          title={gettext("No model provider yet")}
        >
          <p id="providers-none">{gettext("Add a model key, so agents can run.")}</p>
        </.empty_state>

        <.table
          :if={@providers != []}
          id="providers"
          label={list_title()}
          rows={@providers}
          row_id={&"provider-#{&1.public_id}"}
        >
          <:col :let={provider} label={gettext("Provider")} kind="title">
            <.link
              id={"provider-#{provider.public_id}-name"}
              navigate={provider_path(@current_scope, provider)}
              class="truncate hover:underline"
            >
              {provider.name}
            </.link>
          </:col>
          <:col :let={provider} label={gettext("Keys")}>
            <span id={"provider-#{provider.public_id}-keys"} class="text-muted">
              {Format.number(keys(provider))}
            </span>
          </:col>
        </.table>

        <p :if={!@writes} id="providers-who" class="q-foot-note">{who_adds(@current_scope)}</p>
      </.settings_page>
    </Layouts.app>
    """
  end

  # The steps under New model provider's title: where to get a key, then how to add it.
  # The last step names the workspace the reader is in, and is left out without one.
  attr :workspace, :any, required: true

  defp help(assigns) do
    ~H"""
    <div id="new-provider-help" class="grid gap-2 text-[13.5px]/5 text-muted">
      <p>{gettext("First get a key from your model provider:")}</p>
      <ul class="grid list-disc gap-1 pl-5">
        <li>
          <.rich text={
            rich_gettext("%{provider} create an API key in the Claude Console.",
              provider: {:b, gettext("Anthropic API key:")}
            )
          } />
        </li>
        <li>
          <.rich text={
            rich_gettext(
              "%{provider} run %{command} in a terminal where Claude Code is installed, and copy the token it prints. Anthropic's terms allow this for personal use only.",
              provider: {:b, gettext("Claude subscription token:")},
              command: {:m, "claude setup-token"}
            )
          } />
        </li>
        <li>
          <.rich text={
            rich_gettext("%{provider} create a DeepSeek API key.", provider: {:b, "DeepSeek:"})
          } />
        </li>
        <li>
          <.rich text={
            rich_gettext("%{provider} create an OpenRouter API key.",
              provider: {:b, "OpenRouter:"}
            )
          } />
        </li>
        <li>
          <.rich text={
            rich_gettext(
              "%{provider} get a key that your LiteLLM proxy accepts, and the proxy's https address without %{v1}, such as %{example}.",
              provider: {:b, "LiteLLM:"},
              v1: {:m, "/v1"},
              example: {:m, "https://litellm.example.com"}
            )
          } />
        </li>
      </ul>
      <ol class="grid list-decimal gap-1 pl-5">
        <li>
          <.rich text={
            rich_gettext("Open %{place}.",
              place: {:b, gettext("Organisation settings › Model providers › New model provider")}
            )
          } />
        </li>
        <li>
          <.rich text={
            rich_gettext("In %{field}, choose the provider of your key, such as %{example}.",
              field: {:b, gettext("Provider")},
              example: {:b, gettext("Anthropic API key")}
            )
          } />
        </li>
        <li>
          <.rich text={
            rich_gettext(
              "Paste the key in %{key}. For LiteLLM, also enter the proxy's address in %{address}.",
              key: {:b, gettext("Key")},
              address: {:b, gettext("Address")}
            )
          } />
        </li>
        <li>
          <.rich text={rich_gettext("Press %{button}.", button: {:b, gettext("Save")})} />
        </li>
        <li :if={@workspace}>
          <.rich text={
            rich_gettext("In %{place}, choose a model for %{workspace}, and press %{button}.",
              place: {:b, gettext("Workspace settings › Model")},
              workspace: @workspace.name,
              button: {:b, gettext("Save")}
            )
          } />
        </li>
      </ol>
    </div>
    """
  end
end
