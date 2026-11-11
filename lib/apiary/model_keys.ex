defmodule Apiary.ModelKeys do
  @moduledoc """
  The settings and the states of model keys. A model key is one value of a model
  provider's secret, found by the value's row id (`secret_values.id`), which a rename of
  the value id leaves as it is. Both are kept at the key's organisation.

  **Settings** (`Apiary.ModelKeys.Setting`): an optional weekly reset and an optional
  Pause for. `pause_seconds/2` is a key's Pause for: its setting, else the default of the
  provider's catalogue entry, 60 seconds for an API key and 3600 seconds for a
  subscription, whose API's `auth` has `oauth: true`. `next_reset/2` is the next reset of
  a key's weekly schedule after a time. No function here checks access: the caller does.

  **States** (`Apiary.ModelKeys.State`): one row per key and limit window, as the
  gateways of runs report them (`Apiary.ModelKeys.Report`). `record/3` keeps the newest
  row by `observed_at`: an older report never overwrites a newer row, whichever gateway
  sent it. A read leaves out the utilization of a window whose `resets_at` has passed
  (`current/2`). `provider_states/2` is the states of a provider's keys, `known_reset/2`
  a key's known reset, `cooldown_until/1` the end of a key's cooldown, the latest
  `cooldown_until` across its windows, `in_cooldown?/2` whether a key is in cooldown, and
  `cooldown_counts/2` how many keys of each provider are.

  **A run's keys** (`run_keys/1`): the model keys of a run, each with the name of its
  credential in the run's run configuration. A report and its answer reach a key only
  through this function.
  """

  import Ecto.Query, warn: false

  alias Apiary.Connections.Connection
  alias Apiary.Kinds.{Provider, Providers}
  alias Apiary.ModelKeys.{Setting, State}
  alias Apiary.Repo
  alias Apiary.Runs.{ProviderCredential, Run}
  alias Apiary.Secrets.Value

  @api_key_pause_seconds 60
  @subscription_pause_seconds 3600
  @week_days 7

  @typedoc """
  A model key of a run: `name`, the credential's name in the run's run configuration;
  `secret_value_id`, the value's row id; and `organisation_id`, the value's organisation.
  """
  @type run_key :: %{
          name: String.t(),
          secret_value_id: Ecto.UUID.t(),
          organisation_id: Ecto.UUID.t()
        }

  ## Settings

  @doc "The settings of the key `secret_value_id`, or nil when it has none."
  @spec setting(Ecto.UUID.t()) :: Setting.t() | nil
  def setting(secret_value_id), do: Repo.get(Setting, secret_value_id)

  @doc """
  The changeset of the settings of the key `value`, from the settings it has or none, for
  a form.
  """
  @spec change_setting(Value.t(), map) :: Ecto.Changeset.t()
  def change_setting(%Value{} = value, attrs \\ %{}),
    do: value |> setting_of() |> Setting.changeset(attrs)

  @doc """
  Saves the settings of the key `value` (`Apiary.ModelKeys.Setting.changeset/2`), at the
  value's organisation. `{:ok, setting}` or `{:error, changeset}`. The caller checks that
  the person may change the key.
  """
  @spec put_setting(Value.t(), map) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def put_setting(%Value{} = value, attrs) do
    value
    |> change_setting(attrs)
    |> Repo.insert_or_update()
  end

  defp setting_of(%Value{id: id, organisation_id: organisation_id}) do
    Repo.get(Setting, id) || %Setting{secret_value_id: id, organisation_id: organisation_id}
  end

  @doc """
  The Pause for of a key of `provider`, in seconds: the key's setting, else
  `default_pause_seconds/1`.
  """
  @spec pause_seconds(Connection.t(), Setting.t() | nil) :: pos_integer
  def pause_seconds(_provider, %Setting{pause_seconds: seconds}) when is_integer(seconds),
    do: seconds

  def pause_seconds(%Connection{} = provider, _setting), do: default_pause_seconds(provider)

  @doc """
  The default Pause for of the keys of `provider`, in seconds, from its catalogue entry:
  3600 for a subscription, whose API's `auth` has `oauth: true`, and 60 for an API key,
  and for a provider the catalogue no longer has.
  """
  @spec default_pause_seconds(Connection.t()) :: pos_integer
  def default_pause_seconds(%Connection{provider_kind: kind}) do
    case Providers.fetch(kind) do
      {:ok, %Provider{apis: apis}} ->
        if Enum.any?(apis, &(get_in(&1, ["auth", "oauth"]) == true)),
          do: @subscription_pause_seconds,
          else: @api_key_pause_seconds

      :error ->
        @api_key_pause_seconds
    end
  end

  @doc """
  The next reset of the weekly schedule of `setting` after `time`, strictly, in UTC; nil
  for settings with no reset. The reset is the weekday and time in the setting's time
  zone: a time that the clocks skip is the first moment after the gap, and a time that
  happens twice is the first of the two.
  """
  @spec next_reset(Setting.t() | nil, DateTime.t()) :: DateTime.t() | nil
  def next_reset(setting, %DateTime{} = time) do
    if Setting.reset?(setting) do
      local = DateTime.shift_zone!(time, setting.reset_time_zone)
      date = DateTime.to_date(local)
      days = Integer.mod(setting.reset_weekday - Date.day_of_week(date), @week_days)
      first = reset_at(Date.add(date, days), setting)

      if DateTime.compare(first, time) == :gt,
        do: first,
        else: reset_at(Date.add(date, days + @week_days), setting)
    end
  end

  defp reset_at(date, %Setting{reset_time: time, reset_time_zone: zone}) do
    local =
      case DateTime.new(date, time, zone) do
        {:ok, at} -> at
        {:gap, _before, after_gap} -> after_gap
        {:ambiguous, first, _second} -> first
      end

    local |> DateTime.shift_zone!("Etc/UTC") |> usec()
  end

  ## A run's keys

  @doc """
  The model keys of `run`, in the order of its run configuration's `credentials`, each
  with its credential's name: none unless model keys apply, with the `factory` and
  `secrets` features on. A run has one model key: the value of its provider's secret
  with its stored value id, named by the provider's public id, as the run's run
  configuration names its model key. A key whose value was renamed or removed since the
  claim, or whose provider's row no longer has the run's secret, is not a key of the run.
  """
  @spec run_keys(Run.t()) :: [run_key]
  def run_keys(
        %Run{
          provider_api: %{},
          provider_connection_id: connection_id,
          provider_secret_id: secret_id,
          provider_value_id: value_id
        } = _run
      )
      when is_binary(connection_id) and is_binary(secret_id) and is_binary(value_id) do
    if ProviderCredential.applies?() do
      Repo.all(
        from v in Value,
          join: c in Connection,
          on: c.id == ^connection_id and c.secret_id == v.secret_id,
          where: v.secret_id == ^secret_id and v.value_id == ^value_id,
          where: not is_nil(c.provider_kind),
          select: %{name: c.public_id, secret_value_id: v.id, organisation_id: v.organisation_id}
      )
    else
      []
    end
  end

  def run_keys(%Run{}), do: []

  ## States

  @doc """
  Records the reported states `items` of the keys `keys` (`run_keys/1`), at `now`: each
  item names its key by `credential`, and an item of a credential that is not among
  `keys`, or of a window outside `Apiary.ModelKeys.State.windows/0`, is left out. One
  statement writes every row, and keeps a row only where the
  item's `observed_at` is newer than the row's; of two items of one key and window, the
  newer counts. Returns `:ok`.
  """
  @spec record([run_key], [map], DateTime.t()) :: :ok
  def record(keys, items, %DateTime{} = now) do
    by_name = Map.new(keys, &{&1.name, &1})

    rows =
      items
      |> Enum.filter(&State.known_window?(&1.window))
      |> Enum.flat_map(fn item ->
        case Map.fetch(by_name, item.credential) do
          {:ok, key} -> [row(key, item, now)]
          :error -> []
        end
      end)
      |> Enum.group_by(&{&1.secret_value_id, &1.window})
      |> Enum.map(fn {_key_window, rows} -> Enum.max_by(rows, & &1.observed_at, DateTime) end)

    if rows != [] do
      Repo.insert_all(State, rows,
        on_conflict: newer(),
        conflict_target: [:secret_value_id, :window]
      )
    end

    :ok
  end

  defp row(key, item, now) do
    %{
      secret_value_id: key.secret_value_id,
      organisation_id: key.organisation_id,
      window: item.window,
      status: item.status,
      resets_at: usec(item[:resets_at]),
      utilization: item[:utilization],
      cooldown_until: usec(item[:cooldown_until]),
      source: item.source,
      observed_at: usec(item.observed_at),
      updated_at: usec(now)
    }
  end

  # `ON CONFLICT (secret_value_id, "window") DO UPDATE SET … WHERE EXCLUDED.observed_at >
  # model_key_states.observed_at`: the row stays when the report is not newer.
  defp newer do
    from s in State,
      where: fragment("EXCLUDED.observed_at > ?", s.observed_at),
      update: [
        set: [
          status: fragment("EXCLUDED.status"),
          resets_at: fragment("EXCLUDED.resets_at"),
          utilization: fragment("EXCLUDED.utilization"),
          cooldown_until: fragment("EXCLUDED.cooldown_until"),
          source: fragment("EXCLUDED.source"),
          observed_at: fragment("EXCLUDED.observed_at"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
  end

  @doc """
  The states of the keys `keys` (`run_keys/1`), at `now` (`current/2`), each with the
  key's credential name: `[{name, state}]`, in the order of `keys`, then by window. Only
  the windows of `Apiary.ModelKeys.State.windows/0` are read, so a run of at most 6 keys
  has at most 66 states.
  """
  @spec run_states([run_key], DateTime.t()) :: [{String.t(), State.t()}]
  def run_states(keys, %DateTime{} = now) do
    ids = Enum.map(keys, & &1.secret_value_id)

    states =
      from(s in State,
        where: s.secret_value_id in ^ids and s.window in ^State.windows(),
        order_by: [asc: s.window]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.secret_value_id)

    for key <- keys,
        state <- Map.get(states, key.secret_value_id, []),
        do: {key.name, current(state, now)}
  end

  @doc """
  The states of the keys of `provider`, the values of its secret, at `now`
  (`current/2`): a map from each key's row id (`secret_values.id`) to its states by
  window. A key with no state is not in the map.
  """
  @spec provider_states(Connection.t(), DateTime.t()) :: %{Ecto.UUID.t() => [State.t()]}
  def provider_states(%Connection{secret_id: secret_id}, %DateTime{} = now)
      when is_binary(secret_id) do
    from(s in State,
      join: v in Value,
      on: v.id == s.secret_value_id,
      where: v.secret_id == ^secret_id,
      order_by: [asc: s.window]
    )
    |> Repo.all()
    |> Enum.map(&current(&1, now))
    |> Enum.group_by(& &1.secret_value_id)
  end

  def provider_states(%Connection{}, _now), do: %{}

  @doc """
  How many keys of each of `providers` are in cooldown at `now` (`in_cooldown?/2`), in
  one query: a map from each provider's row id to its count, 0 for a provider with none.
  """
  @spec cooldown_counts([Connection.t()], DateTime.t()) :: %{Ecto.UUID.t() => non_neg_integer}
  def cooldown_counts(providers, %DateTime{} = now) when is_list(providers) do
    secret_ids = for %Connection{secret_id: id} <- providers, is_binary(id), do: id

    counts =
      Repo.all(
        from s in State,
          join: v in Value,
          on: v.id == s.secret_value_id,
          where: v.secret_id in ^secret_ids and s.cooldown_until > ^now,
          group_by: v.secret_id,
          select: {v.secret_id, count(s.secret_value_id, :distinct)}
      )
      |> Map.new()

    Map.new(providers, &{&1.id, Map.get(counts, &1.secret_id, 0)})
  end

  @doc """
  `state` as it reads at `now`: the utilization of a window whose `resets_at` has passed
  is absent.
  """
  @spec current(State.t(), DateTime.t()) :: State.t()
  def current(%State{resets_at: %DateTime{} = resets_at} = state, %DateTime{} = now) do
    if DateTime.compare(resets_at, now) == :gt, do: state, else: %{state | utilization: nil}
  end

  def current(%State{} = state, _now), do: state

  @doc """
  The known reset of the key `secret_value_id` at `now`: the earliest `resets_at` after
  `now` across its windows, else the next reset of its weekly schedule after `now`
  (`next_reset/2`), else nil.
  """
  @spec known_reset(Ecto.UUID.t(), DateTime.t()) :: DateTime.t() | nil
  def known_reset(secret_value_id, %DateTime{} = now) do
    earliest =
      Repo.one(
        from s in State,
          where: s.secret_value_id == ^secret_value_id and s.resets_at > ^now,
          select: min(s.resets_at)
      )

    earliest || next_reset(setting(secret_value_id), now)
  end

  @doc """
  The end of the cooldown of the key `secret_value_id`: the latest `cooldown_until`
  across its windows, which only a rejected window has; nil when none has one. A key
  whose 5-hour and 7-day windows are both rejected stays in cooldown until the later of
  the two resets.
  """
  @spec cooldown_until(Ecto.UUID.t()) :: DateTime.t() | nil
  def cooldown_until(secret_value_id) do
    Repo.one(
      from s in State,
        where: s.secret_value_id == ^secret_value_id,
        select: max(s.cooldown_until)
    )
  end

  @doc """
  Whether the key `secret_value_id` is in cooldown at `time`: the end of its cooldown
  (`cooldown_until/1`) is after `time`.
  """
  @spec in_cooldown?(Ecto.UUID.t(), DateTime.t()) :: boolean
  def in_cooldown?(secret_value_id, %DateTime{} = time) do
    case cooldown_until(secret_value_id) do
      %DateTime{} = until -> DateTime.compare(until, time) == :gt
      nil -> false
    end
  end

  defp usec(nil), do: nil

  defp usec(%DateTime{microsecond: {microsecond, _precision}} = time),
    do: %{time | microsecond: {microsecond, 6}}
end
