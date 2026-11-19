defmodule ApiaryWeb.ProviderLive.Show do
  # A model provider's page, Organisation settings › Model providers › its name, with the
  # features `factory` and `secrets`: its keys, the default key first, then in the order
  # they were added, each with its identity line (`Apiary.ModelKeys.Identity`) and its state
  # (`Apiary.ModelKeys`, in words of `ApiaryWeb.ModelKeyComponents.state/4`): Available,
  # with the use and the reset of each window, or In cooldown until a time, and where that
  # time comes from, a window at the key's Use up to percentage included. A key of a
  # provider whose keys are logins (`Apiary.ModelKeys.Login`) has its sign-in too
  # (`ModelKeyComponents.login/2`): Signed in, or Needs a new sign-in, which replaces its
  # state. A key whose provider rejected its value has Needs a new key
  # (`ModelKeyComponents.new_key/2`) in its place. Times are in the reader's time zone. A
  # key is write-only: the page shows no key and no token, and an identity line that has
  # the last 4 characters of a pasted key or the email of a sign-in. Every member reads it
  # (`connection.read`); a provider the organisation does not have is not found.
  #
  # Owners and admins (`provider.write`) have Add key above the keys and Edit on each
  # key's row, each a separate page (`ApiaryWeb.ProviderLive.Key`); anyone else has
  # neither. For a key that needs a new sign-in, they have the button Sign in with ChatGPT
  # in its row, which starts a device sign-in there (`ApiaryWeb.ModelKeyDevice`) and stores
  # it once the person has signed in.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :factory

  on_mount {ApiaryWeb.Features, :secrets}
  on_mount {ApiaryWeb.Access, :"connection.read"}

  alias Apiary.{Access, Connections, ModelKeys}
  alias Apiary.ModelKeys.{Identity, Login}
  alias ApiaryWeb.{ModelKeyComponents, ModelKeyDevice, SettingsComponents}

  @impl true
  def mount(%{"provider_id" => public_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Connections.get_provider(scope, public_id) do
      {:ok, provider} ->
        writes = Access.can?(scope, :"provider.write", scope.organisation)

        {:ok,
         socket
         |> ModelKeyDevice.attach(
           (writes and Login.provider?(provider)) && provider.provider_kind,
           signed_in: &store/1
         )
         |> assign(
           provider: provider,
           writes: writes,
           sections: SettingsComponents.sections(scope, :organisation),
           page_title:
             SettingsComponents.page_title(scope, :organisation, [
               provider.name,
               gettext("Model providers")
             ])
         )
         |> assign_keys()}

      {:error, _reason} ->
        raise ApiaryWeb.NotFound
    end
  end

  defp assign_keys(%{assigns: %{provider: provider}} = socket) do
    now = DateTime.utc_now()
    states = ModelKeys.provider_states(provider, now)
    percents = ModelKeys.use_up_to_percents(provider)
    windows = ModelKeys.limit_windows(provider)
    logins = Login.by_key(provider)
    rejections = ModelKeys.rejections(provider)

    assign(socket,
      keys:
        for key <- in_order(provider) do
          state =
            ModelKeyComponents.state(
              Map.get(states, key.id, []),
              now,
              Map.get(percents, key.id),
              windows
            )

          login = ModelKeyComponents.login(Map.get(logins, key.id), provider)
          new_key = ModelKeyComponents.new_key(Map.get(rejections, key.id), provider)
          # A sign-in rejected by the provider shows as a sign-in that needs a new one.
          rejected = if(match?({:sign_in_needed, _}, new_key), do: new_key)

          %{
            id: key.id,
            identity: Identity.of(provider, key, logins),
            state: state,
            login:
              if(ModelKeyComponents.sign_in_needed?(login),
                do: login,
                else: rejected || login
              ),
            new_key: if(match?({:new_key, _line}, new_key), do: new_key)
          }
        end
    )
  end

  # Stores the sign-in that the person made from a key's row as the key's new value, and
  # shows the key as it is then. A sign-in that cannot be stored shows as one that failed.
  # The key is named by its row id, which the button sends: no page shows the value id.
  defp store(%{assigns: %{device: %{key: key_id}}} = socket) when is_binary(key_id) do
    %{current_scope: scope, provider: provider} = socket.assigns

    with {:ok, value_id} <- value_id_of(provider, key_id),
         {:ok, login} <- ModelKeyDevice.login(socket),
         {:ok, provider} <- Connections.set_provider_key(scope, provider, value_id, login) do
      socket
      |> ModelKeyDevice.reset()
      |> assign(provider: provider)
      |> assign_keys()
      |> put_flash(
        :info,
        gettext("%{identity} is saved.", identity: saved_identity(provider, value_id))
      )
    else
      _refused -> ModelKeyDevice.fail(socket)
    end
  end

  defp store(socket), do: socket

  defp saved_identity(provider, value_id), do: Identity.for_value_id(provider, value_id)

  defp value_id_of(%{secret: %{values: values}}, key_id) when is_list(values) do
    case Enum.find(values, &(&1.id == key_id)) do
      %{value_id: value_id} when is_binary(value_id) -> {:ok, value_id}
      _none -> :error
    end
  end

  defp value_id_of(_provider, _key_id), do: :error

  # The sign-in of a key's row: the one that is going on for the key, else the idle button.
  defp row_device(%{key: key} = device, %{id: key}), do: device
  defp row_device(device, _key), do: %{device | state: :idle, key: nil}

  # Whether the sign-in of another row has a code or is about to have one: the button of
  # this row does nothing until it ends.
  defp busy_elsewhere?(%{key: key, state: state}, %{id: id}),
    do: key != id and state in [:starting, :code]

  defp busy_elsewhere?(_device, _key), do: false

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
            <li :for={key <- @keys} id={"provider-key-#{key.id}"}>
              <span id={"provider-key-#{key.id}-name"}>
                {key.identity}
              </span>
              <ModelKeyComponents.state_line
                :if={!ModelKeyComponents.sign_in_needed?(key.login) and !key.new_key}
                id={"provider-key-#{key.id}-state"}
                state={key.state}
              />
              <ModelKeyComponents.new_key_state
                :if={key.new_key}
                id={"provider-key-#{key.id}-new-key"}
                state={key.new_key}
                provider={@provider}
              />
              <ModelKeyComponents.login_line
                :if={key.login}
                id={"provider-key-#{key.id}-login"}
                login={key.login}
              />
              <ModelKeyComponents.sign_in_with_chatgpt
                :if={@device && ModelKeyComponents.sign_in_needed?(key.login)}
                id={"provider-key-#{key.id}-sign-in"}
                device={row_device(@device, key)}
                key={key.id}
                hint={false}
                disabled={busy_elsewhere?(@device, key)}
              />
              <.link
                :if={@writes}
                id={"provider-key-#{key.id}-edit"}
                navigate={"#{base(@current_scope, @provider)}/keys/#{key.id}/edit"}
                class="ml-auto text-[13px] hover:underline"
                aria-label={gettext("Edit key %{identity}", identity: key.identity)}
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
