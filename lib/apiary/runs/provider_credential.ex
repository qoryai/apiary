defmodule Apiary.Runs.ProviderCredential do
  @moduledoc false

  # The model key of a run that the handover set a model provider for
  # (`Apiary.Dispatches.RunSettings`), as its run configuration contains it: one entry of the
  # contract's `credentials`, an API credential, and the hosts the provider needs, which
  # the run's `egress.allow` and `egress.allow_first` gain
  # (`Apiary.Policy.ComposedConfiguration`). Both come from
  # the run's stored provider columns and the provider's row, so a choice changed after
  # the handover changes neither.
  #
  # The entry has, in the schema's order: `name`, the provider's public id, the same for
  # every run of the provider; `format`, `endpoint` and `auth` of the API the run uses
  # (`runs.provider_api`); and `key_prefixes` when the API has them. It has no key value,
  # no secret id and no value id: the gateway fetches the value with the secrets request
  # (`Apiary.Runs.SecretsRequest`).
  #
  # The hosts are the description's `egress_hosts`, in its order, each once. An entry
  # `{"setting": name}` is the host of that setting's address: the address in
  # `runs.provider_api` when the run's API takes its endpoint from that setting, else the
  # provider's value of the setting. An address that fails the check of
  # `Apiary.Kinds.Endpoint` adds no host, with a line in the log.
  #
  # Only with both features `factory` and `secrets` on; with either off, a run has none.
  # `{:error, :unavailable}` when the run has a provider whose row is gone, fails its
  # integrity code (`Apiary.Connections.intact?/1`), or is no longer in the catalogue as
  # it was added, and when the stored endpoint fails the endpoint rule: the run is then
  # given no run configuration, since one without its key would run on another. Reads; it
  # locks and writes nothing.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{Connections, Edition, Features, Gateways, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.Kinds.{Endpoint, Provider}

  @typedoc """
  A run's model key: the credential's `name`, the `entry` as the run configuration writes
  it, the `hosts` the run reaches it on, and the provider's row it was read from.
  """
  @type t :: %{
          name: String.t(),
          entry: Jason.OrderedObject.t(),
          hosts: [String.t()],
          provider: Connection.t()
        }

  # The order the contract's `auth.schema.json` lists its members in.
  @auth_members ~w(scheme header username oauth)

  @doc false
  @spec for_run(map | nil) :: {:ok, t | nil} | {:error, :unavailable}
  def for_run(%{provider_api: %{} = api} = run) do
    if applies?(), do: credential(run, api), else: {:ok, nil}
  end

  def for_run(_run), do: {:ok, nil}

  @doc false
  # applies?/0 is whether a run with a model provider is given its credential: both
  # features `factory` and `secrets` on.
  @spec applies?() :: boolean
  def applies?, do: Features.on?(:factory) and Features.on?(:secrets)

  @doc false
  # sealable_to?/3 is whether the key of a provider of `chain`, of the run's organisation
  # `run_organisation_id`, may be sealed for a gateway of `gateway_organisation_id`. A
  # provider of the organisation's chain: only for a gateway of the run's organisation. A
  # provider of an operator's chain: only while the edition returns "operator" for the
  # run's organisation (`c:Apiary.Edition.model_choice_chain/1`), and only for a gateway
  # of another organisation whose gateways serve the run's
  # (`Apiary.Gateways.serving_organisations/1`). The handover
  # (`Apiary.Dispatches.Handover`) and the secrets request
  # (`Apiary.Runs.SecretsRequest`) both check it.
  @spec sealable_to?(String.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: boolean
  def sealable_to?("organisation", gateway_organisation_id, run_organisation_id),
    do: gateway_organisation_id == run_organisation_id

  def sealable_to?("operator", gateway_organisation_id, run_organisation_id) do
    gateway_organisation_id != run_organisation_id and
      Edition.model_choice_chain(run_organisation_id) == "operator" and
      gateway_organisation_id in Gateways.serving_organisations(run_organisation_id)
  end

  def sealable_to?(_chain, _gateway_organisation_id, _run_organisation_id), do: false

  defp credential(run, api) do
    with {:ok, provider} <- provider(Map.get(run, :provider_connection_id)),
         :ok <- endpoint(provider, api["endpoint"]),
         {:ok, description} <- description(provider) do
      {:ok,
       %{
         name: provider.public_id,
         entry: entry(provider.public_id, api),
         hosts: hosts(provider, description, api),
         provider: provider
       }}
    end
  end

  # The provider's row as it was written, or `:unavailable` with a line in the log.
  defp provider(id) when is_binary(id) do
    case Repo.one(from c in Connection, where: c.id == ^id and not is_nil(c.provider_kind)) do
      %Connection{} = provider ->
        if Connections.intact?(provider) do
          {:ok, provider}
        else
          Logger.error(
            "a run's model provider #{provider.public_id} fails its integrity code: " <>
              "the run is given no run configuration"
          )

          {:error, :unavailable}
        end

      nil ->
        gone()
    end
  end

  defp provider(nil), do: gone()

  defp gone do
    Logger.error("a run's model provider is gone: the run is given no run configuration")
    {:error, :unavailable}
  end

  defp endpoint(provider, address) do
    case Endpoint.check(address) do
      :ok ->
        :ok

      {:error, _refusal} ->
        Logger.error(
          "the endpoint a run keeps for the model provider #{provider.public_id} fails " <>
            "the endpoint rule: the run is given no run configuration"
        )

        {:error, :unavailable}
    end
  end

  defp description(provider) do
    case Connections.provider(provider) do
      {:ok, %Provider{} = description} ->
        {:ok, description}

      {:error, reason} ->
        Logger.error(
          "the model provider #{provider.public_id} is not in the catalogue as it was " <>
            "added (#{reason}): the run is given no run configuration"
        )

        {:error, :unavailable}
    end
  end

  @doc false
  # entry/2 is the API credential named `name` for `api`, the run's `provider_api`.
  @spec entry(String.t(), map) :: Jason.OrderedObject.t()
  def entry(name, %{"format" => format, "endpoint" => endpoint, "auth" => auth} = api) do
    auth = for member <- @auth_members, Map.has_key?(auth, member), do: {member, auth[member]}

    prefixes =
      case api["key_prefixes"] do
        [_ | _] = prefixes -> [{"key_prefixes", prefixes}]
        _none -> []
      end

    Jason.OrderedObject.new(
      [
        {"name", name},
        {"format", format},
        {"endpoint", endpoint},
        {"auth", Jason.OrderedObject.new(auth)}
      ] ++ prefixes
    )
  end

  defp hosts(provider, %Provider{} = description, api) do
    settings = Connection.settings_map(provider)
    run_setting = run_setting(description, api["format"])

    description.egress_hosts
    |> Enum.flat_map(fn
      host when is_binary(host) ->
        [host]

      %{"setting" => ^run_setting} when is_binary(run_setting) ->
        host(provider, run_setting, api["endpoint"])

      %{"setting" => name} ->
        host(provider, name, settings[name])
    end)
    |> Enum.uniq()
  end

  # The setting the run's API takes its endpoint from, nil for an API with a URL.
  defp run_setting(%Provider{apis: apis}, format) do
    case Enum.find(apis, &(&1["format"] == format)) do
      %{"endpoint" => %{"setting" => name}} -> name
      _other -> nil
    end
  end

  defp host(provider, name, address) do
    case Endpoint.host(address) do
      {:ok, host} ->
        [host]

      :error ->
        Logger.error(
          "the setting #{name} of the model provider #{provider.public_id} is not an " <>
            "address the endpoint rule takes: its host is not added to the run's allow list"
        )

        []
    end
  end
end
