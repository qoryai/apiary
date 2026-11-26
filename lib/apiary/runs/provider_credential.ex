defmodule Apiary.Runs.ProviderCredential do
  @moduledoc false

  # The model keys of a run that its claim stored keys for
  # (`Apiary.Dispatches.RunSettings`), as its run configuration contains them: one entry
  # of the contract's `credentials` per key, an API credential, in the order the run keeps
  # its keys (`run_model_keys`, `Apiary.Runs.ModelKey`); and the hosts its providers need,
  # which the run's `egress.allow` and `egress.allow_first` gain
  # (`Apiary.Policy.ComposedConfiguration`). Both come from the run's key rows and their
  # providers' rows, so a choice or a key's state changed after the claim changes neither.
  # A run's keys may be of several providers, one key group per session
  # (`Apiary.ModelKeys.Group`, `key_groups/2`).
  #
  # Each entry has, in the schema's order: `name`, the key's credential name as the run
  # keeps it; `group`, the same for every key of one key group (`group_names/3`);
  # `format`, `endpoint` and `auth` of the API its row keeps, the same for every key of
  # one key group, `auth` with `account_header` and `account_claim` for an API whose
  # keys are sign-ins that name the account; `paths`, the paths of the endpoint's host the
  # gateway sets the key on, when the API has them; `key_prefixes` when the API has them;
  # and, as the claim wrote them, `resets_at`, `schedule_resets_at`, `pause_for_s`,
  # `cooldown_until` and `use_up_to_percent`, each where the row has it. A key with
  # `use_up_to_percent` also has `use_up_to_windows`, its provider's limit windows, which
  # the claim wrote into the row's API from the catalogue's entry; a row whose API has no
  # windows has neither member, as the contract requires both or none. The default model
  # provider credential, `default_model_provider_credential_name`, is the key the run
  # keeps with `default_credential`, else its first. An entry has no key value, no secret
  # id and no value id: the gateway fetches the values with the secrets request
  # (`Apiary.Runs.SecretsRequest`), which reveals a key by its row id.
  #
  # The hosts are, for each provider of the run's keys, the description's
  # `egress_hosts`, in its order; each host once across the providers. An entry
  # `{"setting": name}` is the host of that setting's address: the address in the API of
  # the provider's rows when that API takes its endpoint from that setting, else the
  # provider's value of the setting. An address that fails the check of
  # `Apiary.Kinds.Endpoint` adds no host, with a line in the log.
  #
  # Only with both features `factory` and `secrets` on; with either off, a run has none.
  # `{:error, :unavailable}` when one of the run's providers has a row that is gone,
  # fails its integrity code (`Apiary.Connections.intact?/1`), or for which
  # `Apiary.Connections.provider/1` returns an error, and when a stored endpoint fails the
  # endpoint rule: the run then has no run configuration, since one without its keys
  # would run on another. A check of a provider's settings that ran out of time or crashed
  # returns `{:error, :unavailable}` too, and the next request checks them again. Each
  # provider's endpoint is checked, and its description read, once. Reads; it locks and
  # writes nothing.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{Connections, Features, Gateways, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.Kinds.{Endpoint, Provider}
  alias Apiary.ModelKeys.Group
  alias Apiary.Nodes.Node
  alias Apiary.Runs.ModelKey

  @typedoc """
  A run's model keys: `name`, the credential name of the default model provider
  credential, the run configuration's `default_model_provider_credential_name`; `keys`,
  each key's credential `name`, row id (`secret_value_id`), `entry` as the run
  configuration writes it, the provider's row it was read from (`provider`) and the run's
  row of it (`row`), in order; the `hosts` the run reaches them on; and the rows of the
  keys' providers, each once, in the order of their keys.
  """
  @type t :: %{
          name: String.t(),
          keys: [
            %{
              name: String.t(),
              secret_value_id: Ecto.UUID.t(),
              entry: Jason.OrderedObject.t(),
              provider: Connection.t(),
              row: ModelKey.t()
            }
          ],
          hosts: [String.t()],
          providers: [Connection.t()]
        }

  # The order the contract's `auth.schema.json` lists its members in.
  @auth_members ~w(scheme header username oauth account_header account_claim)
  # The members a run keeps for each key, in the order of the contract's `api_credential`.
  @key_members ~w(resets_at schedule_resets_at pause_for_s cooldown_until use_up_to_percent)

  @doc false
  # for_run/1 is the model keys of `run` (`t/0`): nil for a run with none. The run's key
  # rows are read by its id, unless `run` has them loaded (`Apiary.Runs.Run`,
  # `model_keys`).
  @spec for_run(map | nil) :: {:ok, t | nil} | {:error, :unavailable}
  def for_run(%{} = run) do
    case rows(run) do
      [_ | _] = rows ->
        if applies?(Apiary.Runs.Run.kept_features(run)),
          do: credential(run, rows),
          else: {:ok, nil}

      [] ->
        {:ok, nil}
    end
  end

  def for_run(_run), do: {:ok, nil}

  @doc false
  # rows/1 is the key rows of `run` in their order (`Apiary.Runs.ModelKey`): those it has
  # loaded, else those read by its id; none for a run with neither.
  @spec rows(map) :: [ModelKey.t()]
  def rows(%{model_keys: rows}) when is_list(rows), do: Enum.sort_by(rows, & &1.position)

  def rows(%{id: id}) when is_binary(id),
    do: Repo.all(from k in ModelKey, where: k.run_id == ^id, order_by: [asc: k.position])

  def rows(_run), do: []

  @doc false
  # workspace_hosts/1 is the hosts of the model providers the model choices that reach
  # `workspace` use, at the organisation's default, the workspace and its targets, for any
  # workflow, as their provider or as one of their fallbacks, since a run of the
  # workspace may be given a fallback's keys: for each provider, the hosts `for_run/1`
  # gives a run of each of its APIs
  # (`hosts/3`). `[%{host:, connection:}]` with the provider's `id`, `public_id` and
  # `name`, each host once per provider. A provider that cannot be read, as `for_run/1`
  # reads it, adds none. A run gains the hosts of the providers and APIs of its keys.
  # `[]` unless `applies?/0`.
  @spec workspace_hosts(Apiary.Organisations.Workspace.t()) :: [
          %{host: String.t(), connection: map}
        ]
  def workspace_hosts(%Apiary.Organisations.Workspace{} = workspace) do
    if applies?() do
      places =
        from m in Apiary.ModelChoices.ModelChoice,
          where: m.organisation_id == ^workspace.organisation_id and m.chain == "organisation",
          where: is_nil(m.workspace_id) or m.workspace_id == ^workspace.id

      chosen =
        Repo.all(
          from m in places,
            where: not is_nil(m.connection_id),
            distinct: true,
            select: m.connection_id
        )

      fallbacks =
        Repo.all(
          from f in Apiary.ModelChoices.Fallback,
            where: f.model_choice_id in subquery(from m in places, select: m.id),
            distinct: true,
            select: f.connection_id
        )

      ids = Enum.uniq(chosen ++ fallbacks)

      from(c in Connection,
        where: c.id in ^ids and not is_nil(c.provider_kind) and c.chain == "organisation",
        order_by: [asc: c.id]
      )
      |> Repo.all()
      |> Enum.flat_map(&provider_hosts/1)
    else
      []
    end
  end

  defp provider_hosts(%Connection{} = provider) do
    with true <- Connections.intact?(provider),
         {:ok, %Provider{apis: apis} = description} <- Connections.provider(provider) do
      settings = Connection.settings_map(provider)

      apis
      |> Enum.flat_map(fn api ->
        address =
          case api["endpoint"] do
            %{"setting" => name} -> settings[name]
            address -> address
          end

        if is_binary(address) and Endpoint.check(address) == :ok,
          do: hosts(provider, description, Map.put(api, "endpoint", address)),
          else: []
      end)
      |> Enum.uniq()
      |> Enum.map(
        &%{
          host: &1,
          connection: %{id: provider.id, public_id: provider.public_id, name: provider.name}
        }
      )
    else
      _not_read -> []
    end
  end

  @doc false
  # applies?/0 is whether a run with a model provider is given its credential: both
  # features `factory` and `secrets` on, as the instance has them now. For a claim, the
  # queue and the pages.
  @spec applies?() :: boolean
  def applies?, do: applies?(nil)

  @doc false
  # applies?/1 is `applies?/0` for a run that kept `recorded`, the names of the features it
  # was claimed with (`Apiary.Runs.Run`, `features`): both on among them. A run that kept
  # none, nil, follows the instance (`Apiary.Features.on?/2`). For a run's requests, so a
  # run already running keeps the features it started with.
  @spec applies?([String.t()] | nil) :: boolean
  def applies?(recorded) when is_list(recorded) or is_nil(recorded),
    do: Features.on?(:factory, recorded) and Features.on?(:secrets, recorded)

  @doc false
  # sealable_to?/3 is whether the key of a provider of `chain`, of a run in the workspace
  # `workspace_id` of the organisation `organisation_id`, may be sealed for `gateway`, by
  # the level it lives at (`Apiary.Gateways.level/1`). Only a key of the organisation's
  # chain: for a gateway of the run's organisation, and a gateway made in a workspace
  # only for a run of that workspace; or for the instance's gateway, which serves every
  # organisation. A key of any other chain is never sealed, and neither is a key for a run
  # map without both `organisation_id` and `workspace_id`. The claim
  # (`Apiary.Dispatches.Handover`) and the secrets request
  # (`Apiary.Runs.SecretsRequest`) both check it.
  @spec sealable_to?(String.t(), Node.t(), %{
          organisation_id: Ecto.UUID.t(),
          workspace_id: Ecto.UUID.t()
        }) :: boolean
  def sealable_to?(
        chain,
        %Node{kind: :gateway} = gateway,
        %{organisation_id: organisation_id, workspace_id: workspace_id}
      )
      when is_binary(organisation_id) do
    (is_nil(gateway.workspace_id) or gateway.workspace_id == workspace_id) and
      sealable_at?(chain, Gateways.level(gateway), gateway.organisation_id, organisation_id)
  end

  def sealable_to?(_chain, _gateway, _run), do: false

  defp sealable_at?("organisation", :instance, nil, _run_organisation_id), do: true

  defp sealable_at?("organisation", _level, gateway_organisation_id, run_organisation_id),
    do: gateway_organisation_id == run_organisation_id

  defp sealable_at?(_chain, _level, _gateway_organisation_id, _run_organisation_id),
    do: false

  defp credential(run, rows) do
    groups = rows |> Enum.group_by(& &1.connection_id) |> Map.new()
    ids = rows |> Enum.map(& &1.connection_id) |> Enum.uniq()

    read =
      Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, read} ->
        api = hd(Map.fetch!(groups, id)).api

        with {:ok, provider} <- provider(id),
             :ok <- endpoint(provider, api["endpoint"]),
             {:ok, description} <- description(provider) do
          {:cont, {:ok, read ++ [{provider, hosts(provider, description, api)}]}}
        else
          {:error, :unavailable} = unavailable -> {:halt, unavailable}
        end
      end)

    with {:ok, read} <- read do
      providers = Map.new(read, fn {provider, _hosts} -> {provider.id, provider} end)
      # Every run with key rows has a row with `default_credential`: a claim stores keys
      # only for a run whose first session has a default model provider credential.
      %ModelKey{name: default_name} = Enum.find(rows, & &1.default_credential)
      group_names = group_names(run, rows, providers)

      keys =
        for row <- rows do
          provider = Map.fetch!(providers, row.connection_id)

          %{
            name: row.name,
            secret_value_id: row.secret_value_id,
            entry: entry(row.name, Map.fetch!(group_names, row.position), row.api, kept(row)),
            provider: provider,
            row: row
          }
        end

      {:ok,
       %{
         name: default_name,
         keys: keys,
         hosts: read |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq(),
         providers: Enum.map(read, &elem(&1, 0))
       }}
    end
  end

  @doc false
  # key_groups/2 is the key rows `rows` by key group, in the order of each group's first
  # row, each group's rows in their order: the rows of one chain and one API whose
  # providers, in `providers` by row id, have one key group identity
  # (`Apiary.ModelKeys.Group.identity/1`). The claim writes every key of one key group, of
  # one or more providers, with the group's chain and API, so two key groups of one run
  # with the same chain and API stay two. A row whose provider is not in `providers` has
  # no identity, and joins the other such rows of its chain and API.
  @spec key_groups([ModelKey.t()], %{Ecto.UUID.t() => Connection.t()}) :: [[ModelKey.t()]]
  def key_groups(rows, providers) when is_list(rows) and is_map(providers) do
    key = fn row ->
      provider = Map.get(providers, row.connection_id)
      {provider && Group.identity(provider), row.chain, row.api}
    end

    by_group = Enum.group_by(rows, key)
    rows |> Enum.map(key) |> Enum.uniq() |> Enum.map(&Map.fetch!(by_group, &1))
  end

  # The `group` of each key row, by its position: for each key group (`key_groups/2`), the
  # public id of the provider of the run's default model provider credential
  # (`provider_connection_id`), the provider of the run's model choice, where the group
  # has a key of it; else that of the provider of the group's first key.
  # shortcut: a later session's group takes the first key's provider, not the provider of
  # that session's model choice; replace when a row keeps its group.
  defp group_names(run, rows, providers) do
    head = Map.get(run, :provider_connection_id)

    for group <- key_groups(rows, providers),
        ids = Enum.map(group, & &1.connection_id),
        id = if(head in ids, do: head, else: hd(ids)),
        row <- group,
        into: %{},
        do: {row.position, Map.fetch!(providers, id).public_id}
  end

  # What a key row keeps for its run configuration entry, by the contract's member names,
  # each where the row has it (`entry/4`).
  defp kept(%ModelKey{} = row) do
    [
      {"resets_at", time(row.resets_at)},
      {"schedule_resets_at", time(row.schedule_resets_at)},
      {"pause_for_s", row.pause_for_s},
      {"cooldown_until", time(row.cooldown_until)},
      {"use_up_to_percent", row.use_up_to_percent}
    ]
    |> Enum.reject(fn {_member, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp time(nil), do: nil
  defp time(%DateTime{} = time), do: DateTime.to_iso8601(time)

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

      {:error, :provider_unchecked} ->
        Logger.error(
          "the check of the settings of the model provider #{provider.public_id} ran out " <>
            "of time or crashed: the run has no run configuration for this request"
        )

        {:error, :unavailable}

      {:error, reason} ->
        Logger.error(
          "the model provider #{provider.public_id} does not fit the catalogue entry of " <>
            "its kind (#{reason}): the run has no run configuration"
        )

        {:error, :unavailable}
    end
  end

  @doc false
  # entry/4 is the API credential named `name` of the key group `group`, the public id of
  # the provider of the run's model choice for the group's keys (`group_names/3`), for
  # `api`, the API of the key's row, with the members the run keeps for the key `key`, by
  # the contract's member names, and with the row's `use_up_to_windows`, from `api`,
  # beside the key's `use_up_to_percent`. The keys of one key group, of one or more
  # providers, are one group for the gateway, which rotates, cools and stops each group
  # apart from the others.
  @spec entry(String.t(), String.t(), map, map) :: Jason.OrderedObject.t()
  def entry(
        name,
        group,
        %{"format" => format, "endpoint" => endpoint, "auth" => auth} = api,
        key \\ %{}
      ) do
    auth = for member <- @auth_members, Map.has_key?(auth, member), do: {member, auth[member]}

    prefixes =
      case api["key_prefixes"] do
        [_ | _] = prefixes -> [{"key_prefixes", prefixes}]
        _none -> []
      end

    paths =
      case api["paths"] do
        [_ | _] = paths -> [{"paths", paths}]
        _none -> []
      end

    kept = for member <- @key_members, Map.has_key?(key, member), do: {member, key[member]}

    # `use_up_to_percent` and `use_up_to_windows` go together, or neither does.
    kept =
      case {key["use_up_to_percent"], api["use_up_to_windows"]} do
        {percent, [_ | _] = windows} when is_integer(percent) ->
          kept ++ [{"use_up_to_windows", windows}]

        _neither ->
          List.keydelete(kept, "use_up_to_percent", 0)
      end

    Jason.OrderedObject.new(
      [
        {"name", name},
        {"group", group},
        {"format", format},
        {"endpoint", endpoint},
        {"auth", Jason.OrderedObject.new(auth)}
      ] ++ paths ++ prefixes ++ kept
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
