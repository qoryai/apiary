defmodule ApiaryWeb.ProviderLive.Show do
  # A model provider's page, Organisation settings › Model providers › its name, with the
  # features `factory` and `secrets`: its keys, each by its value id. A key is write-only:
  # the page shows a mask in its place, never the key nor a part of it. Every member reads
  # it (`connection.read`); a provider the organisation does not have is not found.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  on_mount {ApiaryWeb.Features, :secrets}
  on_mount {ApiaryWeb.Access, :"connection.read"}

  alias Apiary.Connections
  alias ApiaryWeb.SettingsComponents

  @impl true
  def mount(%{"provider_id" => public_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Connections.get_provider(scope, public_id) do
      {:ok, provider} ->
        {:ok,
         assign(socket,
           provider: provider,
           keys: provider.secret.values,
           sections: SettingsComponents.sections(scope, :organisation),
           page_title:
             SettingsComponents.page_title(scope, :organisation, [
               provider.name,
               gettext("Model providers")
             ])
         )}

      {:error, _reason} ->
        raise ApiaryWeb.NotFound
    end
  end

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
      <:crumb title={@provider.name}>{@provider.name}</:crumb>

      <.settings_page section={:model_providers} title={@provider.name}>
        <SettingsComponents.part id="provider-keys" title={gettext("Keys")}>
          <ul class="q-plain-list">
            <li :for={key <- @keys} id={"provider-key-#{key.value_id}"}>
              <span class="font-mono text-[12.5px] text-muted">{key.value_id}</span>
              <span class="font-mono text-muted" aria-hidden="true">••••••••••••</span>
            </li>
          </ul>
        </SettingsComponents.part>
      </.settings_page>
    </Layouts.app>
    """
  end
end
