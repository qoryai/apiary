defmodule ApiaryWeb.ProviderLive.Show do
  # A model provider's page, Organisation settings › Model providers › its name, with the
  # features `factory` and `secrets`: its keys, the default key first, then in the order
  # they were added, each with its name and its state (`Apiary.ModelKeys`, in words of
  # `ApiaryWeb.ModelKeyComponents.state/4`): Available, with the use and the reset of each
  # window, or In cooldown until a time, and where that time comes from, a window at the
  # key's Use up to percentage included. Times are in the
  # reader's time zone. A key is write-only: the page shows neither the key nor a part of
  # it. Every member reads it (`connection.read`); a provider the organisation does not
  # have is not found.
  #
  # Owners and admins (`provider.write`) have Add key above the keys and Edit on each
  # key's row, each a separate page (`ApiaryWeb.ProviderLive.Key`); anyone else has
  # neither.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  on_mount {ApiaryWeb.Features, :secrets}
  on_mount {ApiaryWeb.Access, :"connection.read"}

  alias Apiary.{Access, Connections, ModelKeys}
  alias ApiaryWeb.{ModelKeyComponents, SettingsComponents}

  @impl true
  def mount(%{"provider_id" => public_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Connections.get_provider(scope, public_id) do
      {:ok, provider} ->
        now = DateTime.utc_now()
        states = ModelKeys.provider_states(provider, now)
        percents = ModelKeys.use_up_to_percents(provider)
        windows = ModelKeys.limit_windows(provider)

        {:ok,
         assign(socket,
           provider: provider,
           keys:
             for key <- in_order(provider) do
               state =
                 ModelKeyComponents.state(
                   Map.get(states, key.id, []),
                   now,
                   Map.get(percents, key.id),
                   windows
                 )

               %{value_id: key.value_id, state: state}
             end,
           writes: Access.can?(scope, :"provider.write", scope.organisation),
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

  # The provider's keys in its order: the default key first, then by when each was added.
  defp in_order(%{secret: %{values: values}, default_value_id: default}) when is_list(values),
    do:
      Enum.sort_by(
        values,
        &{&1.value_id != default, DateTime.to_unix(&1.inserted_at, :microsecond)}
      )

  defp in_order(_provider), do: []

  defp base(scope, provider),
    do: ~p"/#{scope.organisation}/settings/model-providers/#{provider.public_id}"

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
        <:actions :if={@writes}>
          <.button
            id="provider-add-key"
            variant="primary"
            navigate={"#{base(@current_scope, @provider)}/keys/new"}
          >
            {gettext("Add key")}
          </.button>
        </:actions>

        <SettingsComponents.part id="provider-keys" title={gettext("Keys")}>
          <ul class="q-plain-list">
            <li :for={key <- @keys} id={"provider-key-#{key.value_id}"}>
              <span id={"provider-key-#{key.value_id}-name"} class="font-mono text-[12.5px]">
                {key.value_id}
              </span>
              <ModelKeyComponents.state_line
                id={"provider-key-#{key.value_id}-state"}
                state={key.state}
              />
              <.link
                :if={@writes}
                id={"provider-key-#{key.value_id}-edit"}
                navigate={"#{base(@current_scope, @provider)}/keys/#{key.value_id}/edit"}
                class="ml-auto text-[13px] hover:underline"
                aria-label={gettext("Edit key %{name}", name: key.value_id)}
              >
                {gettext("Edit")}
              </.link>
            </li>
          </ul>
        </SettingsComponents.part>
      </.settings_page>
    </Layouts.app>
    """
  end
end
