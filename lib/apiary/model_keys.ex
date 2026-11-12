defmodule Apiary.ModelKeys do
  @moduledoc """
  The settings and the states of model keys. A model key is one value of a model
  provider's secret, found by the value's row id (`secret_values.id`), which a rename of
  the value id leaves as it is. Both are kept at the key's organisation.

  **Settings** (`Apiary.ModelKeys.Setting`): an optional weekly reset, an optional
  Pause for and an optional Use up to percentage. `pause_seconds/2` is a key's Pause
  for: its setting, else the default of the provider's catalogue entry, 60 seconds for an
  API key and 3600 seconds for a subscription, whose API's `auth` has `oauth: true`.
  `next_reset/2` is the next reset of a key's weekly schedule after a time. Use up to is
  only for a key of a provider whose catalogue entry lists limit windows
  (`limit_windows/1`). No function here checks access: the caller does.

  **States** (`Apiary.ModelKeys.State`): one row per key and limit window, as the
  gateways of runs report them (`Apiary.ModelKeys.Report`). `record/3` keeps the newest
  row by `observed_at`: an older report never overwrites a newer row, whichever gateway
  sent it. A read leaves out the utilization of a window whose `resets_at` has passed
  (`current/2`). `provider_states/2` is the states of a provider's keys, and
  `cooldown_counts/2` how many keys of each provider are in cooldown. `cooldown/4` is
  whether a key is in cooldown, and until when: while one of its windows has a
  `cooldown_until` in the future, or while one of its provider's limit windows has a
  utilization at or above the key's Use up to percentage and a reset in the future. Every
  reader of a key's cooldown here goes through it, and the claim's filter
  (`claimable/1`) is its SQL. A new value of a key deletes its states
  (`clear_states/2`); a rename keeps them.

  **A run's keys** (`run_keys/1`): the model keys of a run, each with the name of its
  credential in the run's run configuration and the time the run's value of it was set.
  A gateway's report, and the response Qory Apiary returns for it
  (`Apiary.ModelKeys.Report.answer/5`), reach a key only through this function. A
  gateway's secrets request keeps which value of each key it sealed for the run
  (`keep_copies/2`, `Apiary.ModelKeys.Copy`); migration 20261111220000 wrote such a copy
  for each key of each run that was pending or running at the upgrade.

  **At a claim** (`claim_keys/3`): the keys of a provider with their resets, cooldowns
  and Pause for, which `Apiary.ModelKeys.Order` orders. A claim passes a run of the queue
  while every key of each of its providers is in cooldown (`claimable/1`), and the run
  waits until `cooling_until/2`.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.Connections.Connection
  alias Apiary.Kinds.{Provider, Providers}
  alias Apiary.ModelKeys.{Copy, Setting, State}
  alias Apiary.Repo
  alias Apiary.Runs.{ProviderCredential, Run}
  alias Apiary.Secrets.Value

  @api_key_pause_seconds 60
  @subscription_pause_seconds 3600
  @week_days 7

  @typedoc """
  A model key of a run: `name`, the credential's name in the run's run configuration;
  `secret_value_id`, the value's row id; `organisation_id`, the value's organisation;
  `copy_set_at`, when the value the run has was set (`run_keys/1`), nil when unknown; and
  `copy_kept`, true when `copy_set_at` is the `value_set_at` of a copy of the key for the
  run (`Apiary.ModelKeys.Copy`), which a secrets request kept (`keep_copies/2`) or
  migration 20261111220000 wrote for a run that was pending or running at the upgrade;
  false when it is the time the run's row was written.
  """
  @type run_key :: %{
          name: String.t(),
          secret_value_id: Ecto.UUID.t(),
          organisation_id: Ecto.UUID.t(),
          copy_set_at: DateTime.t() | nil,
          copy_kept: boolean
        }

  ## Settings

  @doc "The settings of the key `secret_value_id`, or nil when it has none."
  @spec setting(Ecto.UUID.t()) :: Setting.t() | nil
  def setting(secret_value_id), do: Repo.get(Setting, secret_value_id)

  @doc """
  The changeset of the settings of the key `value`, from the settings it has or none, for
  a form. `limit_windows` is the key's provider's (`limit_windows/1`): without them, the
  changeset has an error for a Use up to percentage.
  """
  @spec change_setting(Value.t(), map, [String.t()]) :: Ecto.Changeset.t()
  def change_setting(%Value{} = value, attrs \\ %{}, limit_windows \\ []),
    do: value |> setting_of() |> Setting.changeset(attrs, limit_windows)

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
  The limit windows of `provider`'s catalogue entry, the windows a key's Use up to
  percentage applies to, such as `five_hour` and `seven_day`: `[]` for a provider whose
  entry has none, and for one the catalogue no longer has. A key of a provider without
  them has no Use up to percentage.
  """
  @spec limit_windows(Connection.t() | String.t() | nil) :: [String.t()]
  def limit_windows(%Connection{provider_kind: kind}), do: limit_windows(kind)

  def limit_windows(kind) when is_binary(kind) do
    case Providers.fetch(kind) do
      {:ok, %Provider{limit_windows: windows}} -> windows
      :error -> []
    end
  end

  def limit_windows(nil), do: []

  @doc """
  The Use up to percentage of each key of `provider` that has one, by the key's row id
  (`secret_values.id`): none for a provider without limit windows (`limit_windows/1`),
  whose keys' stored percentages are ignored.
  """
  @spec use_up_to_percents(Connection.t()) :: %{Ecto.UUID.t() => pos_integer}
  def use_up_to_percents(%Connection{secret_id: secret_id} = provider)
      when is_binary(secret_id) do
    if limit_windows(provider) == [] do
      %{}
    else
      Repo.all(
        from st in Setting,
          join: v in Value,
          on: v.id == st.secret_value_id,
          where: v.secret_id == ^secret_id and not is_nil(st.use_up_to_percent),
          select: {st.secret_value_id, st.use_up_to_percent}
      )
      |> Map.new()
    end
  end

  def use_up_to_percents(%Connection{}), do: %{}

  @doc """
  Whether a key is in cooldown at `now`, from `states`, its states by window, and until
  when: `{until, {:stored, state}}` while a window's `cooldown_until` is after `now`, from
  a provider's limit error, a schedule or a Pause for; `{until, {:use_up_to, state}}`
  while a window of `limit_windows` (`limit_windows/1`) has a utilization at or above
  `percent`, the key's Use up to percentage, and a `resets_at` after `now`, until that
  reset. Of several, the latest end, a stored cooldown first at the same end. Nil for a
  key out of cooldown. A nil `percent`, or no `limit_windows`, leaves out the second
  kind.
  """
  @spec cooldown([State.t() | map], pos_integer | nil, [String.t()], DateTime.t()) ::
          {DateTime.t(), {:stored | :use_up_to, State.t() | map}} | nil
  def cooldown(states, percent, limit_windows, %DateTime{} = now) do
    stored =
      for %{cooldown_until: %DateTime{} = until} = state <- states,
          after?(until, now),
          do: {until, {:stored, state}}

    use_up_to =
      for %{window: window, utilization: used, resets_at: %DateTime{} = reset} = state <- states,
          is_integer(percent) and is_integer(used) and used >= percent,
          window in limit_windows,
          after?(reset, now),
          do: {reset, {:use_up_to, state}}

    case stored ++ use_up_to do
      [] -> nil
      cooldowns -> Enum.max_by(cooldowns, &elem(&1, 0), DateTime)
    end
  end

  # The limit windows of every provider of the catalogue that has them, by its kind, for
  # the claim's filter (`claimable/1`).
  defp limit_windows_by_kind do
    for %Provider{name: name, limit_windows: [_ | _] = windows} <- Providers.list(),
        into: %{},
        do: {name, windows}
  end

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
  happens twice is the first of the two. A zone that the time zone database no longer
  has is read as UTC, with one warning in the log for each key and zone, the first time
  the node reads that zone for that key.
  """
  @spec next_reset(Setting.t() | nil, DateTime.t()) :: DateTime.t() | nil
  def next_reset(setting, %DateTime{} = time) do
    if Setting.reset?(setting) do
      setting = known_zone(setting)
      local = DateTime.shift_zone!(time, setting.reset_time_zone)
      date = DateTime.to_date(local)
      days = Integer.mod(setting.reset_weekday - Date.day_of_week(date), @week_days)
      first = reset_at(Date.add(date, days), setting)

      if DateTime.compare(first, time) == :gt,
        do: first,
        else: reset_at(Date.add(date, days + @week_days), setting)
    end
  end

  defp known_zone(%Setting{reset_time_zone: zone} = setting) do
    case DateTime.shift_zone(~U[2026-01-01 00:00:00Z], zone) do
      {:ok, _time} ->
        setting

      {:error, _reason} ->
        warn_unknown_zone(setting)
        %{setting | reset_time_zone: "Etc/UTC"}
    end
  end

  # One warning for each key and zone on this node: a `:persistent_term` mark, written
  # once, so later reads of the key log nothing. The marks are as many as the keys whose
  # zone the database dropped.
  defp warn_unknown_zone(%Setting{secret_value_id: id, reset_time_zone: zone}) do
    mark = {__MODULE__, :unknown_zone, id, zone}

    unless :persistent_term.get(mark, false) do
      :persistent_term.put(mark, true)

      Logger.warning(
        "a model key's reset time zone is not in the time zone database; " <>
          "its reset is read in UTC key=#{id}"
      )
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
  `secrets` features on. They are the keys the run's claim stored (`runs.model_keys`),
  each by its row id, so a key renamed since the claim stays a key of the run. A key
  removed since the claim, or no longer a value of the run's secret, and every key of a
  run whose provider's row no longer has that secret, is not a key of the run.

  Each has `copy_set_at`, when the value the run has was set: that of the value a secrets
  request sealed for the run last (`keep_copies/2`), with `copy_kept` true; for a key no
  request sealed, the time the run's row was written, as the run has no value set later
  than that, with `copy_kept` false; nil for a run not stored. The upgrade that added the
  copies wrote one for each key of each pending or running run, with the key's
  `value_set_at` at the upgrade, so such a run is not compared by the time its row was
  written.
  """
  @spec run_keys(Run.t()) :: [run_key]
  def run_keys(
        %Run{
          provider_api: %{},
          provider_connection_id: connection_id,
          provider_secret_id: secret_id,
          model_keys: [_ | _] = keys
        } = run
      )
      when is_binary(connection_id) and is_binary(secret_id) do
    if ProviderCredential.applies?() do
      ids = for %{"id" => id} <- keys, do: id

      found =
        Repo.all(
          from v in Value,
            join: c in Connection,
            on: c.id == ^connection_id and c.secret_id == v.secret_id,
            where: v.secret_id == ^secret_id and v.id in ^ids,
            where: not is_nil(c.provider_kind),
            select: {v.id, v.organisation_id}
        )
        |> Map.new()

      copies = copies(run, ids)

      for %{"id" => id, "name" => name} <- keys,
          organisation_id = found[id],
          organisation_id != nil,
          do: %{
            name: name,
            secret_value_id: id,
            organisation_id: organisation_id,
            copy_set_at: Map.get(copies, id, run.inserted_at),
            copy_kept: Map.has_key?(copies, id)
          }
    else
      []
    end
  end

  def run_keys(%Run{}), do: []

  # The `value_set_at` of the value of each key of `ids` that a secrets request sealed for
  # `run` last, or that migration 20261111220000 copied for a run pending or running at
  # the upgrade, by the key's row id.
  defp copies(%Run{id: run_id}, ids) when is_binary(run_id) do
    Repo.all(
      from c in Copy,
        where: c.run_id == ^run_id and c.secret_value_id in ^ids,
        select: {c.secret_value_id, c.value_set_at}
    )
    |> Map.new()
  end

  defp copies(%Run{}, _ids), do: %{}

  @doc """
  Keeps, for the run `run_id`, which value of each of its keys a secrets request sealed:
  `copies`, `[{secret_value_id, value_set_at}]`, each the key's row id and when the
  sealed value was set, read from the row the value was read from.
  One row per run and key (`Apiary.ModelKeys.Copy`), the last request's. Each statement
  takes the run's row and the key's row `FOR KEY SHARE`, in the order of the keys' ids,
  then the copy's row: a key or a run deleted since the request is left out, as a copy
  goes with either. In the caller's transaction. Returns `:ok`.
  """
  @spec keep_copies(Ecto.UUID.t(), [{Ecto.UUID.t(), DateTime.t()}]) :: :ok
  def keep_copies(run_id, copies) when is_binary(run_id) and is_list(copies) do
    for {id, %DateTime{} = value_set_at} <- Enum.sort(copies) do
      Repo.insert_all(
        Copy,
        from(v in Value,
          join: r in Run,
          on: r.id == ^run_id,
          where: v.id == ^id,
          lock: "FOR KEY SHARE",
          select: %{
            run_id: r.id,
            secret_value_id: v.id,
            value_set_at: type(^usec(value_set_at), :utc_datetime_usec)
          }
        ),
        on_conflict: {:replace, [:value_set_at]},
        conflict_target: [:run_id, :secret_value_id]
      )
    end

    :ok
  end

  ## Keys at a claim

  @typedoc """
  A key of a provider at a claim (`claim_keys/3`), as `Apiary.ModelKeys.Order` reads it,
  with what a run configuration writes of it.
  """
  @type claim_key :: %{
          id: Ecto.UUID.t(),
          value_id: String.t(),
          inserted_at: DateTime.t(),
          named: boolean,
          default: boolean,
          resets_at: DateTime.t() | nil,
          schedule_resets_at: DateTime.t() | nil,
          known_reset: DateTime.t() | nil,
          cooldown_until: DateTime.t() | nil,
          pause_seconds: pos_integer,
          use_up_to_percent: pos_integer | nil
        }

  @doc """
  The keys of `provider`, the values of its secret, at `now`, for a claim: each with its
  row id and value id; whether it is the key `named_value_id`, which a model choice
  names (nil for none), and whether it is the provider's default key; `resets_at`, the
  earliest reset after `now` across its windows, from the providers' responses;
  `schedule_resets_at`, the next reset of its weekly schedule (`next_reset/2`);
  `known_reset`, its known reset, the first of those two that it has; `cooldown_until`,
  the end of its cooldown at `now` (`cooldown/4`), nil for a key out of cooldown: the
  latest `cooldown_until` across its windows, which only a rejected window has, so a key
  whose 5-hour and 7-day windows are both rejected stays in cooldown until the later of
  the two, or the reset of a limit window whose use is at or above its Use up to
  percentage, whichever ends later; its Pause for (`pause_seconds/2`); and
  `use_up_to_percent`, its Use up to percentage, nil for none and for every key of a
  provider without limit windows (`limit_windows/1`). In no order: the order is
  `Apiary.ModelKeys.Order.order/2`. Three reads, none locked.
  """
  @spec claim_keys(Connection.t(), String.t() | nil, DateTime.t()) :: [claim_key]
  def claim_keys(%Connection{secret_id: secret_id} = provider, named_value_id, %DateTime{} = now)
      when is_binary(secret_id) do
    values =
      Repo.all(
        from v in Value,
          where: v.secret_id == ^secret_id,
          select: %{id: v.id, value_id: v.value_id, inserted_at: v.inserted_at}
      )

    ids = Enum.map(values, & &1.id)

    states =
      from(s in State, where: s.secret_value_id in ^ids)
      |> Repo.all()
      |> Enum.group_by(& &1.secret_value_id)

    settings =
      from(st in Setting, where: st.secret_value_id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.secret_value_id, &1})

    windows = limit_windows(provider)

    for value <- values do
      key_states = Map.get(states, value.id, [])
      setting = Map.get(settings, value.id)
      schedule = next_reset(setting, now)
      percent = if windows != [] and setting, do: setting.use_up_to_percent
      resets_at = earliest_reset(key_states, now)

      Map.merge(value, %{
        named: is_binary(named_value_id) and value.value_id == named_value_id,
        default: is_binary(value.value_id) and value.value_id == provider.default_value_id,
        resets_at: resets_at,
        schedule_resets_at: schedule,
        known_reset: resets_at || schedule,
        cooldown_until: cooldown_end(key_states, percent, windows, now),
        pause_seconds: pause_seconds(provider, setting),
        use_up_to_percent: percent
      })
    end
  end

  def claim_keys(%Connection{}, _named_value_id, _now), do: []

  ## The claim's filter

  @doc """
  The condition, on a run of the queue bound `:run`, that a claim at `now` may take it by
  its model providers (`dispatch_runs.model_provider_ids`): it has none, or one of them is
  not cooling. A provider is cooling at `now` while it has keys and every one of them is
  in cooldown, as `cooldown/4` has it, in SQL: a state of the key has a `cooldown_until`
  after `now`, or a state of one of the provider's limit windows (`limit_windows/1`) has
  a utilization at or above the key's Use up to percentage and a `resets_at` after
  `now`. A provider that is gone, or has no keys, is not cooling, so the claim takes the
  run and ends it as it would without a cooldown. The condition reads every key of every
  provider of the run.

  With `except:`, a list of provider row ids, those providers count as cooling. A claim
  sets it to the providers whose settings check stopped earlier in that claim.
  """
  @spec claimable(DateTime.t(), [{:except, [Ecto.UUID.t()]}]) :: Ecto.Query.dynamic_expr()
  def claimable(%DateTime{} = now, opts \\ []) do
    except = Keyword.get(opts, :except, [])

    # `= '{}'`, not `cardinality(…) = 0`: Postgres reads the column's statistics for the
    # first and none for the second, and with a low guess of the runs it passes it plans
    # the claim's other joins as nested loops over the whole queue.
    dynamic(
      [run: r],
      fragment("? = '{}'::uuid[]", r.model_provider_ids) or
        fragment(
          """
          EXISTS (SELECT 1 FROM unnest(?) AS p(id) WHERE p.id <> ALL(?) AND NOT EXISTS (
            SELECT 1 FROM organisation_connections c
            WHERE c.id = p.id AND c.provider_kind IS NOT NULL
              AND EXISTS (SELECT 1 FROM secret_values v WHERE v.secret_id = c.secret_id)
              AND NOT EXISTS (
                SELECT 1 FROM secret_values v WHERE v.secret_id = c.secret_id
                  AND NOT EXISTS (SELECT 1 FROM model_key_states s
                    WHERE s.secret_value_id = v.id AND (s.cooldown_until > ?
                      OR (s.resets_at > ? AND s.utilization >= (
                            SELECT st.use_up_to_percent FROM model_key_settings st
                            WHERE st.secret_value_id = v.id)
                          AND s."window" IN (
                            SELECT jsonb_array_elements_text(?::jsonb -> c.provider_kind))))))))
          """,
          r.model_provider_ids,
          type(^except, {:array, Ecto.UUID}),
          type(^usec(now), :utc_datetime_usec),
          type(^usec(now), :utc_datetime_usec),
          type(^limit_windows_by_kind(), :map)
        )
    )
  end

  @doc """
  When the first key of the providers `provider_ids` leaves its cooldown, while every one
  of them is cooling at `now`, as `claimable/1` reads it: the earliest end of a key's
  cooldown (`cooldown/4`) across their keys. Nil when one of them is not cooling, and for
  no providers.
  """
  @spec cooling_until([Ecto.UUID.t()], DateTime.t()) :: DateTime.t() | nil
  def cooling_until(provider_ids, %DateTime{} = now) do
    case first_to_leave(provider_ids, now) do
      {_provider_id, until} -> until
      nil -> nil
    end
  end

  @doc """
  The provider of `provider_ids` whose key leaves its cooldown first, and when, while
  every one of them is cooling at `now` (`cooling_until/2`): `{provider_id, until}`. Of two
  providers whose keys leave at the same time, the earlier in `provider_ids`. Nil when
  one of them is not cooling, and for no providers.
  """
  @spec first_to_leave([Ecto.UUID.t()], DateTime.t()) :: {Ecto.UUID.t(), DateTime.t()} | nil
  def first_to_leave([], _now), do: nil

  def first_to_leave(provider_ids, %DateTime{} = now) when is_list(provider_ids) do
    ids = Enum.uniq(provider_ids)

    # The end of each key's cooldown, nil for a key out of cooldown, by provider.
    ends =
      from(c in Connection,
        join: v in Value,
        on: v.secret_id == c.secret_id,
        left_join: s in State,
        on: s.secret_value_id == v.id,
        left_join: st in Setting,
        on: st.secret_value_id == v.id,
        where: c.id in ^ids and not is_nil(c.provider_kind),
        select: {c.id, c.provider_kind, v.id, s, st.use_up_to_percent}
      )
      |> Repo.all()
      |> Enum.group_by(fn {id, kind, key_id, _state, percent} -> {id, kind, key_id, percent} end)
      |> Enum.map(fn {{id, kind, _key_id, percent}, rows} ->
        states = for {_id, _kind, _key_id, %State{} = state, _percent} <- rows, do: state
        {id, cooldown_end(states, percent, limit_windows(kind), now)}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    cooling? =
      Enum.all?(ids, fn id ->
        case Map.get(ends, id) do
          [_ | _] = untils -> Enum.all?(untils, &after?(&1, now))
          nil -> false
        end
      end)

    if cooling? do
      ids
      |> Enum.map(&{&1, Enum.min(Map.fetch!(ends, &1), DateTime)})
      |> Enum.min_by(&elem(&1, 1), DateTime)
    end
  end

  # The end of a key's cooldown at `now` (`cooldown/4`), nil for none.
  defp cooldown_end(states, percent, limit_windows, now) do
    case cooldown(states, percent, limit_windows, now) do
      {until, _source} -> until
      nil -> nil
    end
  end

  defp after?(%DateTime{} = time, now), do: DateTime.compare(time, now) == :gt
  defp after?(nil, _now), do: false

  # The earliest reset after `now` across `states`, nil for none.
  defp earliest_reset(states, now) do
    states
    |> Enum.map(& &1.resets_at)
    |> Enum.filter(&after?(&1, now))
    |> Enum.min(DateTime, fn -> nil end)
  end

  ## States

  @doc """
  Records the reported states `items` of the keys `keys` (`run_keys/1`), at `now`: each
  item names its key by `credential`, and an item of a credential that is not among
  `keys`, or of a window outside `Apiary.ModelKeys.State.windows/0`, is left out. One
  statement writes every row, and keeps a row only where the
  item's `observed_at` is newer than the row's; of two items of one key and window, the
  newer counts. The rows are written in the order of their key's row id and window. A
  key deleted before the write is left out: its value's row is locked `FOR SHARE`
  first, so a deletion waits for the write or comes before it. So does a new value of
  the key (`clear_states/2`): a key whose value is not the value the run has is left
  out, so a run that still has the old value brings back no cooldown on the new one. A
  key with a kept copy (`copy_kept`) is the run's value when its `value_set_at` equals
  the copy's `copy_set_at`, which is an exact copy of that column, so the clocks of
  several servers do not matter. A key with no kept copy is the run's value when its
  `value_set_at` is not after the run's insert (`copy_set_at`). A nil `copy_set_at` is
  left out. A rename leaves `value_set_at` as it is. Returns `:ok`.
  """
  @spec record([run_key], [map], DateTime.t()) :: :ok
  def record(keys, items, %DateTime{} = now) do
    by_name = Map.new(keys, &{&1.name, &1})
    copies = Map.new(keys, &{&1.secret_value_id, {&1.copy_kept, &1.copy_set_at}})

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
      # In one order for every report, so two reports of the same keys at once take the
      # rows' locks in the same order and never wait for each other.
      |> Enum.sort_by(&{&1.secret_value_id, &1.window})

    if rows != [] do
      {:ok, :ok} = Repo.transact(fn -> {:ok, write_states(rows, copies)} end)
    end

    :ok
  end

  # The rows of the keys that still exist, whose value the run has (`copies`), written
  # after their values' rows are locked in the order of their ids, the order of a deletion
  # and of a new value: the value, then its states. `FOR SHARE` waits for a new value's
  # update of the row, which then reads as set, and the new value's deletion of the
  # states waits for this write.
  defp write_states(rows, copies) do
    ids = rows |> Enum.map(& &1.secret_value_id) |> Enum.uniq()

    set =
      Repo.all(
        from v in Value,
          where: v.id in ^ids,
          order_by: v.id,
          lock: "FOR SHARE",
          select: {v.id, v.value_set_at}
      )
      |> Map.new()

    case Enum.filter(rows, &current?(&1, set, copies)) do
      [] ->
        :ok

      kept_rows ->
        Repo.insert_all(State, kept_rows,
          on_conflict: newer(),
          conflict_target: [:secret_value_id, :window]
        )

        :ok
    end
  end

  # Whether the run has the key's value: a kept copy of exactly the key's `value_set_at`,
  # or, with no kept copy, a run written no earlier than the key's value was set.
  defp current?(row, set, copies) do
    case {Map.fetch(set, row.secret_value_id), Map.get(copies, row.secret_value_id)} do
      {{:ok, set_at}, {true, %DateTime{} = copy_set_at}} ->
        DateTime.compare(copy_set_at, set_at) == :eq

      {{:ok, set_at}, {false, %DateTime{} = inserted_at}} ->
        DateTime.compare(inserted_at, set_at) != :lt

      _gone_or_unknown ->
        false
    end
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
  Deletes the states of the key `value_id` of the secret `secret_id`, in the caller's
  transaction: a key whose value changes leaves its cooldowns, which were the old
  value's. Returns `:ok`.
  """
  @spec clear_states(Ecto.UUID.t(), String.t()) :: :ok
  def clear_states(secret_id, value_id) when is_binary(secret_id) and is_binary(value_id) do
    values = from v in Value, where: v.secret_id == ^secret_id and v.value_id == ^value_id

    Repo.delete_all(
      from s in State, where: s.secret_value_id in subquery(select(values, [v], v.id))
    )

    :ok
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
  How many keys of each of `providers` are in cooldown at `now` (`cooldown/4`), in one
  query: a map from each provider's row id to its count, 0 for a provider with none.
  """
  @spec cooldown_counts([Connection.t()], DateTime.t()) :: %{Ecto.UUID.t() => non_neg_integer}
  def cooldown_counts(providers, %DateTime{} = now) when is_list(providers) do
    secret_ids = for %Connection{secret_id: id} <- providers, is_binary(id), do: id

    # Each key's states and Use up to percentage, by its secret and its row id.
    keys =
      Repo.all(
        from s in State,
          join: v in Value,
          on: v.id == s.secret_value_id,
          left_join: st in Setting,
          on: st.secret_value_id == v.id,
          where: v.secret_id in ^secret_ids,
          select: {v.secret_id, v.id, s, st.use_up_to_percent}
      )
      |> Enum.group_by(fn {secret_id, id, _state, percent} -> {secret_id, id, percent} end)
      |> Enum.map(fn {key, rows} -> {key, Enum.map(rows, &elem(&1, 2))} end)

    windows = Map.new(providers, &{&1.secret_id, limit_windows(&1)})

    cooling =
      for {{secret_id, _id, percent}, states} <- keys,
          cooldown(states, percent, Map.get(windows, secret_id, []), now) != nil,
          reduce: %{} do
        acc -> Map.update(acc, secret_id, 1, &(&1 + 1))
      end

    Map.new(providers, &{&1.id, Map.get(cooling, &1.secret_id, 0)})
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

  defp usec(nil), do: nil

  defp usec(%DateTime{microsecond: {microsecond, _precision}} = time),
    do: %{time | microsecond: {microsecond, 6}}
end
