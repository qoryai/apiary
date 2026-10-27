defmodule ApiaryWeb.ProviderLive.Index do
  # Organisation settings › Model providers, with the features `factory` and `secrets`:
  # the list of the organisation's model providers (`:index`), each by its name with how
  # many keys it has, its name leading to its page (`ApiaryWeb.ProviderLive.Show`), and
  # New model provider (`:new`), a separate page that adds one with its key
  # (`Apiary.Connections.create_provider/2`): Provider, Key, and an Address for a
  # provider whose description has an address setting, such as LiteLLM. Beside the form,
  # About this step says what a key is for and where to get the chosen provider's key.
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
            type="choice"
            label={gettext("Provider")}
            options={provider_options()}
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
            hint={gettext("The proxy's https address without /v1.")}
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
        <:context>
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

  # The context of New model provider: what a key is for, where to get the chosen
  # provider's key, and the model to choose next. The last sentence names the workspace the
  # reader is in, and is left out without one.
  attr :organisation, :any, required: true
  attr :workspace, :any, required: true
  attr :chosen, :any, required: true

  defp context(assigns) do
    ~H"""
    <p id="new-provider-what">
      {gettext("A model provider's key lets the agents of %{organisation}'s runs call a model.",
        organisation: @organisation.name
      )}
    </p>
    <p :if={get_key(@chosen)} id="new-provider-get-key">
      <.rich text={get_key(@chosen)}>
        <:part name={:terms}><.terms href={terms_url(@chosen)} /></:part>
      </.rich>
    </p>
    <p :if={@workspace} id="new-provider-next">
      {gettext("After you save, choose %{workspace}'s model in Workspace settings › Model.",
        workspace: @workspace.name
      )}
    </p>
    """
  end

  # Where to get the key of the chosen provider, none for one not in this list.
  defp get_key(%Provider{name: "anthropic"}),
    do: gettext("Get the key from the provider first: create an API key in the Claude Console.")

  defp get_key(%Provider{name: "claude-subscription"}),
    do:
      rich_gettext(
        "Get the key from the provider first: run %{command} in a terminal where Claude Code is installed, and copy the token it prints. %{terms} allow this for personal use only.",
        command: {:m, "claude setup-token"},
        terms: {:part, :terms}
      )

  defp get_key(%Provider{name: "deepseek"}),
    do: gettext("Get the key from the provider first: create a DeepSeek API key.")

  defp get_key(%Provider{name: "openrouter"}),
    do: gettext("Get the key from the provider first: create an OpenRouter API key.")

  defp get_key(%Provider{name: "litellm"}),
    do:
      rich_gettext(
        "First get a key that your LiteLLM proxy accepts, and the proxy's https address without %{v1}, such as %{example}.",
        v1: {:m, "/v1"},
        example: {:m, "https://litellm.example.com"}
      )

  defp get_key(_chosen), do: nil

  # Anthropic's terms, a link out to `href`, or plain words where the description has no
  # address.
  @doc false
  attr :href, :string, required: true

  def terms(assigns) do
    ~H"""
    <.external_link :if={@href} href={@href}>{gettext("Anthropic's terms")}</.external_link>
    <span :if={!@href}>{gettext("Anthropic's terms")}</span>
    """
  end

  # Each provider of the catalogue, its description's text under its title. A subtitle is
  # plain text: the description's backticks and the address that ends it, which
  # About this step links to (`terms_url/1`), are left out.
  defp provider_options do
    for provider <- Providers.list() do
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
