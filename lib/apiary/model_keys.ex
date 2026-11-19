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

  **Keys that need a new value**: a key is skipped at a claim, as a key in cooldown with no
  end, while its sign-in needs a new one (`Apiary.ModelKeys.Login`, the state
  `sign_in_needed`, or an access token with no account claim) or while its provider has
  rejected its value with a 401 that a gateway reported (`Apiary.ModelKeys.Rejection`, the
  state `new_key_needed`, `reject/3`). Such a key stays so until it gets a new value, which
  also ends a rejection when it equals the old value. A sign-in whose access token expires
  before the run's time limit ends is skipped too, while a refresh in the background
  (the job `LoginRefreshJob`) makes it usable. Nothing here calls a provider.

  **A run's keys** (`run_keys/1`): the model keys of a run, each with the name of its
  credential in the run's run configuration and the time the run's value of it was set.
  A gateway's report, and the response Qory Apiary returns for it
  (`Apiary.ModelKeys.Report.answer/5`), reach a key only through this function. A
  gateway's secrets request keeps which value of each key it sealed for the run
  (`keep_copies/2`, `Apiary.ModelKeys.Copy`); migration 20261111220000 wrote such a copy
  for each key of each run that was pending or running at the upgrade.

  **At a claim** (`claim_keys/3`): the keys of a provider with their resets, cooldowns
  and Pause for, which `Apiary.ModelKeys.Order` orders. A claim passes a run of the queue
  while every key of each of its providers is in cooldown or needs a new value
  (`claimable/1`), and the run waits until `cooling_until/2`, or, where no key leaves its
  cooldown by itself, until a person gives a key a new value.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.Connections.Connection
  alias Apiary.Kinds.{Provider, Providers}
  alias Apiary.ModelKeys.{Copy, Login, Rejection, Setting, State}
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
  false when it is the time the run's row was written; and `copy_login_at`, for a sign-in,
  the time of its sign-in or last refresh when the request read the token it sealed for
  the run (`Apiary.ModelKeys.Copy`), nil when the key is no sign-in or the copy has none;
  and `copy_login_sealed_at`, the database's time at which the run's copy took that token.
  """
  @type run_key :: %{
          name: String.t(),
          secret_value_id: Ecto.UUID.t(),
          organisation_id: Ecto.UUID.t(),
          copy_set_at: DateTime.t() | nil,
          copy_kept: boolean,
          copy_login_at: DateTime.t() | nil,
          copy_login_sealed_at: DateTime.t() | nil
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
  `secrets` features on among `features`: by default the ones the run kept when it was
  claimed, until it has ended, or the instance's for a run that has ended or kept none
  (`Apiary.Runs.Run.kept_features/1`). They are the keys the run's claim stored
  (`runs.model_keys`), each by its row id, so a key renamed since the claim stays a key of
  the run. A key removed since the claim, or no longer a value of the run's secret, and
  every key of a run whose provider's row no longer has that secret, is not a key of the
  run.

  Each has `copy_set_at`, when the value the run has was set: that of the value a secrets
  request sealed for the run last (`keep_copies/2`), with `copy_kept` true; for a key no
  request sealed, the time the run's row was written, as the run has no value set later
  than that, with `copy_kept` false; nil for a run not stored. The upgrade that added the
  copies wrote one for each key of each pending or running run, with the key's
  `value_set_at` at the upgrade, so such a run is not compared by the time its row was
  written.
  """
  @spec run_keys(Run.t(), [String.t()] | nil) :: [run_key]
  def run_keys(run, features \\ :kept)

  def run_keys(%Run{} = run, :kept), do: run_keys(run, Run.kept_features(run))

  def run_keys(
        %Run{
          provider_api: %{},
          provider_connection_id: connection_id,
          provider_secret_id: secret_id,
          model_keys: [_ | _] = keys
        } = run,
        features
      )
      when is_binary(connection_id) and is_binary(secret_id) do
    if ProviderCredential.applies?(features) do
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
            copy_set_at: copies |> Map.get(id, {run.inserted_at, nil, nil}) |> elem(0),
            copy_kept: Map.has_key?(copies, id),
            copy_login_at: copies |> Map.get(id, {nil, nil, nil}) |> elem(1),
            copy_login_sealed_at: copies |> Map.get(id, {nil, nil, nil}) |> elem(2)
          }
    else
      []
    end
  end

  def run_keys(%Run{}, _features), do: []

  # The `value_set_at` of the value of each key of `ids` that a secrets request sealed for
  # `run` last, or that migration 20261111220000 copied for a run pending or running at
  # the upgrade, with the sign-in time of the token sealed (`login_at`) and the time the
  # copy took it (`login_sealed_at`), by the key's row id:
  # `{value_set_at, login_at, login_sealed_at}`.
  defp copies(%Run{id: run_id}, ids) when is_binary(run_id) do
    Repo.all(
      from c in Copy,
        where: c.run_id == ^run_id and c.secret_value_id in ^ids,
        select: {c.secret_value_id, {c.value_set_at, c.login_at, c.login_sealed_at}}
    )
    |> Map.new()
  end

  defp copies(%Run{}, _ids), do: %{}

  @doc """
  Keeps, for the run `run_id`, which value of each of its keys a secrets request sealed:
  `copies`, `[{secret_value_id, value_set_at}]` or, for a sign-in,
  `[{secret_value_id, value_set_at, login_at}]`, each the key's row id, when the sealed
  value was set, read from the row the value was read from, and the time of the sign-in or
  of its last refresh when the token was read (`Apiary.ModelKeys.Copy`).
  One row per run and key (`Apiary.ModelKeys.Copy`), the last request's. Each statement
  takes the run's row and the key's row `FOR KEY SHARE`, in the order of the keys' ids,
  then the copy's row: a key or a run deleted since the request is left out, as a copy
  goes with either. In the caller's transaction. Returns `:ok`.
  """
  @spec keep_copies(Ecto.UUID.t(), [
          {Ecto.UUID.t(), DateTime.t()} | {Ecto.UUID.t(), DateTime.t(), DateTime.t() | nil}
        ]) :: :ok
  def keep_copies(run_id, copies) when is_binary(run_id) and is_list(copies) do
    for {id, %DateTime{} = value_set_at, login_at} <- copies |> Enum.map(&copy/1) |> Enum.sort() do
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
            value_set_at: type(^usec(value_set_at), :utc_datetime_usec),
            login_at: type(^usec(login_at), :utc_datetime_usec),
            login_sealed_at:
              fragment(
                "CASE WHEN ?::timestamp IS NULL THEN NULL ELSE clock_timestamp() END",
                type(^usec(login_at), :utc_datetime_usec)
              )
          }
        ),
        on_conflict:
          from(c in Copy,
            update: [
              set: [
                value_set_at: fragment("EXCLUDED.value_set_at"),
                login_at: fragment("EXCLUDED.login_at"),
                login_sealed_at:
                  fragment(
                    "CASE WHEN EXCLUDED.login_at IS NULL THEN NULL WHEN EXCLUDED.login_at IS NOT DISTINCT FROM ? THEN ? ELSE EXCLUDED.login_sealed_at END",
                    c.login_at,
                    c.login_sealed_at
                  )
              ]
            ]
          ),
        conflict_target: [:run_id, :secret_value_id]
      )
    end

    :ok
  end

  defp copy({id, set_at}), do: {id, set_at, nil}
  defp copy({_id, _set_at, _login_at} = copy), do: copy

  @doc """
  The sign-in time (`Apiary.ModelKeys.Copy`, `login_at`) of the token that the last
  secrets request sealed for the run `run_id` and the key `secret_value_id`: a time, or nil
  for a key with no copy, a key that is no sign-in, and a copy that has none. The renewal
  after a 401 serves a token newer than it (`Apiary.ModelKeys.Login`, the `newer_than:` option of its access token read).
  """
  @spec sealed_login_at(Ecto.UUID.t(), Ecto.UUID.t()) :: DateTime.t() | nil
  def sealed_login_at(run_id, secret_value_id) do
    Repo.one(
      from c in Copy,
        where: c.run_id == ^run_id and c.secret_value_id == ^secret_value_id,
        select: c.login_at
    )
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
          use_up_to_percent: pos_integer | nil,
          blocked: blocked
        }

  @typedoc """
  Why a key is not given to a run, nil for a key that is: `:new_key`, its provider rejected
  the value (`Apiary.ModelKeys.Rejection`); `:sign_in`, its sign-in needs a new one;
  `:due`, `:refreshing` or `{:retry, retry_at}`, its access token expires before the end of
  the run's time limit and the refresh has not started, runs, or waits for `retry_at`
  (`Apiary.ModelKeys.Login.status/2`). A key in cooldown is not blocked: the order has it.
  """
  @type blocked ::
          nil | :new_key | :sign_in | :due | :refreshing | {:retry, DateTime.t()}

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
  provider without limit windows (`limit_windows/1`); and `blocked`, why the key is not
  given to a run, nil for a key that is (`t:blocked/0`). In no order: the order is
  `Apiary.ModelKeys.Order.order/2`. A few reads, none locked; the keys of a provider whose
  keys are sign-ins are decrypted to read their expiry and account claim
  (`Apiary.ModelKeys.Login.statuses/3`), and no call is made to any provider.

  `opts`: `expires_before:`, the time a run needs a sign-in's access token until, its start
  plus its time limit; a sign-in that expires before it is `blocked`. Without it, only a
  sign-in that needs a new one is. `decrypt: false` reads the sign-ins' rows alone, so no
  token is decrypted: the read of a page's render, which has no account claim to check.
  """
  @spec claim_keys(Connection.t(), String.t() | nil, DateTime.t(), keyword) :: [claim_key]
  def claim_keys(provider, named_value_id, now, opts \\ [])

  def claim_keys(
        %Connection{secret_id: secret_id} = provider,
        named_value_id,
        %DateTime{} = now,
        opts
      )
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
    rejected = Rejection.live_ids([secret_id])

    logins =
      Login.statuses(provider, ids,
        expires_before: opts[:expires_before],
        decrypt: Keyword.get(opts, :decrypt, true)
      )

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
        use_up_to_percent: percent,
        blocked: blocked(MapSet.member?(rejected, value.id), Map.get(logins, value.id, :ready))
      })
    end
  end

  def claim_keys(%Connection{}, _named_value_id, _now, _opts), do: []

  defp blocked(true, _login), do: :new_key
  defp blocked(false, :ready), do: nil
  defp blocked(false, :sign_in_needed), do: :sign_in
  defp blocked(false, status), do: status

  ## The gate to a key's value

  @doc """
  The one place that reveals a model key's value to be sealed to a run's gateway, for the
  secrets endpoint alone (the secrets request of a run): the key `secret_value_id` of
  `provider`, a row of `Apiary.Connections` the caller has read and checked, for the run
  `run`. Returns `{:ok, value, expires_at, value_set_at}`, `expires_at` nil for a key that
  has none, or `{:error, reason}`.

  A key that needs a new value, because its provider rejected the value it has
  (`Apiary.ModelKeys.Rejection`), is not revealed: `{:error, :new_key_needed}`, as the
  claim does not give it to a run. A key of a provider whose keys are sign-ins
  (`Apiary.ModelKeys.Login`) is not revealed either: its access token is, refreshed first
  when that is due, with the time the token expires, and the refresh token never leaves the
  vault. The token is refused, as `{:error, :sign_in_needed}`, when it has no account id
  (`Apiary.ModelKeys.Login.account?/2`), and no call is made to any provider for that. Any
  other key is its stored value, read as `Apiary.Secrets` reads it (`{:error, :not_found}`
  for a key that is gone, `{:error, :unavailable}` for one that cannot be decrypted), and
  `expires_at` and `login_at` are nil. `login_at` is, for a sign-in, the time of the
  sign-in or of its last refresh that was read before the token was, so that it is never
  later than the token's (`Apiary.ModelKeys.Copy`).

  `opts` (for a sign-in): `recover: true`, the renewal after a 401 of the provider to the
  key, at most once per sign-in in 5 minutes; `newer_than:`, with it, the `login_at` the
  run has: a sign-in that holds a token newer than that serves it; and `wait:`, the
  milliseconds a call waits for a refresh. The reasons of a sign-in are those of the access
  token read of `Apiary.ModelKeys.Login`.
  """
  @spec reveal_for_sealing(Connection.t(), Ecto.UUID.t(), Run.t(), keyword) ::
          {:ok, String.t(), DateTime.t() | nil, DateTime.t() | nil, DateTime.t() | nil}
          | {:error, :not_found | :unavailable | :sign_in_needed | :new_key_needed}
  def reveal_for_sealing(%Connection{} = provider, secret_value_id, %Run{} = run, opts) do
    cond do
      rejected?(provider, secret_value_id) ->
        {:error, :new_key_needed}

      Login.provider?(provider) ->
        reveal_login(provider, secret_value_id, run, opts)

      true ->
        with {:ok, value, set_at} <-
               Apiary.Secrets.reveal_key_and_set_at(provider, secret_value_id),
             do: {:ok, value, nil, set_at, nil}
    end
  end

  # Whether the key's provider rejected the value it has (`Apiary.ModelKeys.Rejection`).
  defp rejected?(%Connection{secret_id: secret_id}, secret_value_id) when is_binary(secret_id) do
    case Ecto.UUID.cast(secret_value_id) do
      {:ok, id} ->
        from(r in Rejection,
          as: :rejection,
          join: v in Value,
          as: :value,
          on: v.id == r.secret_value_id,
          where: v.id == ^id and v.secret_id == ^secret_id
        )
        |> Rejection.live()
        |> Repo.exists?()

      :error ->
        false
    end
  end

  defp rejected?(%Connection{}, _secret_value_id), do: false

  # The sign-in time kept for the run (`login_at`) is the time of the token it gets
  # (`Login.time_of_token/3`), so a run whose request made the refresh has the
  # refresh's time. When another caller's refresh replaced the token between the reads, it
  # is the time read before the token, which is older than the token: a 401 for it marks
  # nothing, and the renewal that follows serves the stored token and keeps its time, so
  # the next 401 marks the key.
  defp reveal_login(provider, secret_value_id, run, opts) do
    with {:ok, set_at, login_at} <- Login.seal_times(provider, secret_value_id),
         {:ok, token, expires_at} <-
           Login.access_token(provider, secret_value_id,
             trigger: {:run, run.public_id},
             recover: Keyword.get(opts, :recover, false),
             newer_than: Keyword.get(opts, :newer_than),
             wait: Keyword.fetch!(opts, :wait)
           ),
         true <- Login.account?(provider, token) || {:error, :sign_in_needed} do
      {:ok, token, expires_at, set_at,
       Login.time_of_token(provider, secret_value_id, token) || login_at}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  ## The claim's filter

  @doc """
  The condition, on a run of the queue bound `:run`, that a claim at `now` may take it by
  its model providers (`dispatch_runs.model_provider_ids`): it has none, or one of them is
  not cooling. A provider is cooling at `now` while it has keys and every one of them is
  in cooldown, as `cooldown/4` has it, in SQL: a state of the key has a `cooldown_until`
  after `now`, or a state of one of the provider's limit windows (`limit_windows/1`) has
  a utilization at or above the key's Use up to percentage and a `resets_at` after
  `now`; or it needs a new value, a cooldown with no end: its sign-in is `sign_in_needed`,
  or its provider rejected its value and the key's value is the one that was rejected
  (`Apiary.ModelKeys.Rejection`). A sign-in that expires before the run's time limit ends
  is not in this condition: the time limit is the claim's to read
  (the claim's run settings). A provider that is gone, or has no keys, is not
  cooling, so the claim takes the run and ends it as it would without a cooldown. The
  condition reads every key of every provider of the run.

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
                  AND NOT EXISTS (SELECT 1 FROM model_key_logins l
                    WHERE l.secret_value_id = v.id AND l.state = 'sign_in_needed')
                  AND NOT EXISTS (SELECT 1 FROM model_key_rejections r
                    WHERE r.secret_value_id = v.id
                      AND r.value_set_at IS NOT DISTINCT FROM v.value_set_at)
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
  every one of them is cooling at `now` (`cooling_until/2`): `{provider_id, until}`. A key
  that needs a new value (`never_ids/1`) is in cooldown with no end: it counts as cooling
  and leaves at no time. Of two providers whose keys leave at the same time, the earlier
  in `provider_ids`. Nil when one of them is not cooling, and when no key of them leaves
  its cooldown by itself, the run waits for a new value then. Nil for no providers.
  """
  @spec first_to_leave([Ecto.UUID.t()], DateTime.t()) :: {Ecto.UUID.t(), DateTime.t()} | nil
  def first_to_leave([], _now), do: nil

  def first_to_leave(provider_ids, %DateTime{} = now) when is_list(provider_ids) do
    ids = Enum.uniq(provider_ids)

    rows =
      from(c in Connection,
        join: v in Value,
        on: v.secret_id == c.secret_id,
        left_join: s in State,
        on: s.secret_value_id == v.id,
        left_join: st in Setting,
        on: st.secret_value_id == v.id,
        where: c.id in ^ids and not is_nil(c.provider_kind),
        select: {c.id, c.provider_kind, c.secret_id, v.id, s, st.use_up_to_percent}
      )
      |> Repo.all()

    never = rows |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> never_ids()

    # The end of each key's cooldown by provider: a time, `:never`, or nil for a key out of
    # cooldown.
    ends =
      rows
      |> Enum.group_by(fn {id, kind, _secret_id, key_id, _state, percent} ->
        {id, kind, key_id, percent}
      end)
      |> Enum.map(fn {{id, kind, key_id, percent}, rows} ->
        states =
          for {_id, _kind, _secret_id, _key_id, %State{} = state, _percent} <- rows, do: state

        end_of =
          if MapSet.member?(never, key_id),
            do: :never,
            else: cooldown_end(states, percent, limit_windows(kind), now)

        {id, end_of}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    cooling? =
      Enum.all?(ids, fn id ->
        case Map.get(ends, id) do
          [_ | _] = untils -> Enum.all?(untils, &(&1 == :never or after?(&1, now)))
          nil -> false
        end
      end)

    if cooling? do
      leaving =
        for id <- ids,
            untils = Enum.filter(Map.fetch!(ends, id), &is_struct(&1, DateTime)),
            untils != [],
            do: {id, Enum.min(untils, DateTime)}

      if leaving != [], do: Enum.min_by(leaving, &elem(&1, 1), DateTime)
    end
  end

  @doc """
  The row ids of the keys among the values of the secrets `secret_ids` that need a new
  value, a cooldown with no end: a sign-in that needs a new one
  (`Apiary.ModelKeys.Login`, `sign_in_needed`), and a key whose provider rejected its
  value, while the key's value is the one that was rejected (`Apiary.ModelKeys.Rejection`).
  Reads the rows alone: no token is decrypted (`Apiary.ModelKeys.Login.statuses/3` reads
  the tokens).
  """
  @spec never_ids([Ecto.UUID.t()]) :: MapSet.t()
  def never_ids([]), do: MapSet.new()

  def never_ids(secret_ids) when is_list(secret_ids) do
    sign_in =
      Repo.all(
        from l in Login,
          join: v in Value,
          on: v.id == l.secret_value_id,
          where: v.secret_id in ^secret_ids and l.state == "sign_in_needed",
          select: v.id
      )

    MapSet.union(MapSet.new(sign_in), Rejection.live_ids(secret_ids))
  end

  @doc """
  Why the run whose model providers are `provider_ids` has no key to be given at `now`,
  for its page: nil while one of the providers has a key that a claim gives, and for a
  provider that has none; else, of the keys the claim does not give, the first that
  applies:

    1. `{:refreshing, provider, value_id}`: a sign-in that a refresh in the background
       makes usable, one that runs, one that is retried after a failure, or, `{:restart,
       provider, value_id}`, one whose refresh starts after this node starts again, as
       this node is stopping (the check of `Login`'s `stopping?/0`);
    2. `{:cooldown, provider, until}`: the key that leaves its cooldown first;
    3. `{:sign_in, provider, value_id}`: a sign-in that needs a new one, and
       `{:new_key, provider, value_id}`, a key whose provider rejected its value; each
       needs a person to give the key a new value. When both kinds are there, the first of
       them in the order the claim sends the keys (`Apiary.ModelKeys.Order.sent/2`).

  `provider` is the provider's row, `value_id` the key's name. `expires_before:` and
  `decrypt:` are as `claim_keys/4` has them. Reads without a lock; no call to any provider.
  """
  @spec waiting_reason([Ecto.UUID.t()], DateTime.t(), keyword) ::
          {:refreshing | :restart | :sign_in | :new_key, Connection.t(), String.t()}
          | {:cooldown, Connection.t(), DateTime.t()}
          | nil
  def waiting_reason(provider_ids, %DateTime{} = now, opts \\ []) when is_list(provider_ids) do
    ids = Enum.uniq(provider_ids)

    keyed =
      from(c in Connection,
        where: c.id in ^ids and not is_nil(c.provider_kind) and not is_nil(c.secret_id)
      )
      |> Repo.all()
      |> Enum.sort_by(&Enum.find_index(ids, fn id -> id == &1.id end))
      |> Enum.map(&{&1, claim_keys(&1, nil, now, opts)})

    cond do
      keyed == [] or length(keyed) < length(ids) -> nil
      Enum.any?(keyed, fn {_provider, keys} -> keys == [] end) -> nil
      Enum.any?(keyed, fn {_provider, keys} -> Enum.any?(keys, &free?(&1, now)) end) -> nil
      true -> unfree_reason(keyed, now)
    end
  end

  # A key a claim gives: not blocked, not in cooldown.
  defp free?(%{blocked: nil} = key, now), do: not Apiary.ModelKeys.Order.cooling?(key, now)
  defp free?(_key, _now), do: false

  defp unfree_reason(keyed, now) do
    all = for {provider, keys} <- keyed, key <- keys, do: {provider, key}
    refresh = Enum.find(all, fn {_provider, key} -> refresh_block?(key.blocked) end)

    cooling =
      for {provider, key} <- all,
          is_nil(key.blocked),
          key.cooldown_until != nil and after?(key.cooldown_until, now),
          do: {provider, key}

    cond do
      refresh ->
        {provider, key} = refresh

        if key.blocked == :due and Login.stopping?(),
          do: {:restart, provider, key.value_id},
          else: {:refreshing, provider, key.value_id}

      cooling != [] ->
        {provider, key} =
          Enum.min_by(cooling, fn {_provider, key} -> key.cooldown_until end, DateTime)

        {:cooldown, provider, key.cooldown_until}

      true ->
        # The first key a person has to fix, in the order the claim sends the keys
        # (`Apiary.ModelKeys.Order.sent/2`), the providers in the run's order.
        needing =
          for {provider, keys} <- keyed,
              key <-
                keys
                |> Enum.filter(&(&1.blocked in [:sign_in, :new_key]))
                |> Apiary.ModelKeys.Order.sent(now),
              do: {provider, key}

        case List.first(needing) do
          {provider, %{blocked: :sign_in} = key} -> {:sign_in, provider, key.value_id}
          {provider, %{blocked: :new_key} = key} -> {:new_key, provider, key.value_id}
          nil -> nil
        end
    end
  end

  defp refresh_block?(:due), do: true
  defp refresh_block?(:refreshing), do: true
  defp refresh_block?({:retry, _at}), do: true
  defp refresh_block?(_blocked), do: false

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

    # The rejection of the old value (`reject/4`): the new value is not the one the provider
    # rejected. A row left by another write path stops counting by itself, as its
    # `value_set_at` is no longer the key's (`Apiary.ModelKeys.Rejection.live/1`).
    Repo.delete_all(
      from r in Rejection, where: r.secret_value_id in subquery(select(values, [v], v.id))
    )

    :ok
  end

  @doc """
  Marks the keys of a run whose provider returned 401, as the run's gateway reports them
  (`Apiary.ModelKeys.Report`, `unauthorized`): `entries`, `[%{credential:, at:}]`, the key's
  credential name and when the 401 arrived, for the run's keys `keys` (`run_keys/1`) of
  `provider`. Each key leaves the claim (`Apiary.ModelKeys.Rejection`) until it gets a new
  value, and the key's page says that the provider rejected it at `at`.

  An entry of a credential that is not among `keys` is left out. So is one of a key whose
  value the run does not have (a new value was set since the run's request that sealed it:
  `record/3` reads that as it does for states), and one of a key of a provider whose keys are
  sign-ins, unless no refresh can fix it for the token the run has
  (`Apiary.ModelKeys.Login.rejectable?/3`, by the run's copy of the sign-in time and the
  database's clock): the gateway lists such a key while its renewal is pending. An entry
  whose `at` is before the time the run's copy took the token it has now is for an earlier
  token and marks nothing (`for_an_older_token?/2`). A refresh never changes the row;
  a new sign-in ends the state, as a new value of any key does. An entry that is older
  than the key's row keeps the row. The rows are written in the order of the keys' row
  ids, after the values' rows are locked `FOR SHARE`, as `record/3` does, so a new value
  and this write take turns. Returns `:ok`.
  """
  @spec reject(
          [run_key],
          [%{credential: String.t(), at: DateTime.t()}],
          Connection.t() | nil,
          DateTime.t()
        ) ::
          :ok
  def reject(keys, entries, provider, %DateTime{} = now) do
    by_name = Map.new(keys, &{&1.name, &1})
    copies = Map.new(keys, &{&1.secret_value_id, {&1.copy_kept, &1.copy_set_at}})
    sealed = Map.new(keys, &{&1.secret_value_id, Map.get(&1, :copy_login_at)})

    marked =
      for entry <- entries,
          {:ok, key} <- [Map.fetch(by_name, entry.credential)],
          not for_an_older_token?(key, entry.at),
          do: {key, entry.at}

    if marked != [] do
      rows =
        for {key, at} <- marked do
          %{
            secret_value_id: key.secret_value_id,
            organisation_id: key.organisation_id,
            rejected_at: usec(at),
            updated_at: usec(now)
          }
        end
        |> Enum.sort_by(& &1.secret_value_id)

      {:ok, :ok} =
        Repo.transact(fn -> {:ok, write_rejections(rows, copies, sealed, provider)} end)
    end

    :ok
  end

  # An entry whose `at`, the gateway's clock when the 401 arrived, is before the database's
  # time at which the run's copy took the token it has now (`copy_login_sealed_at`) is for
  # an earlier token: a report sent again after a renewal, a 401 of a request that was in
  # flight before it, or one repeated because the renewal's answer was lost. The two times
  # are only compared with each other, as stored: the gateway's clock is not compared with
  # any clock here. A copy with no such time (a key that is no sign-in, or a copy written
  # before the column) drops nothing.
  #
  # This is the narrow rule. A report that names the token the gateway sent (a member of
  # `unauthorized` in the contract) would decide this exactly, and no clock would be
  # compared; that is a change of the Forager contract, which this piece does not make.
  defp for_an_older_token?(%{copy_login_sealed_at: %DateTime{} = sealed_at}, %DateTime{} = at),
    do: DateTime.compare(at, sealed_at) == :lt

  defp for_an_older_token?(_key, _at), do: false

  # A key that is no sign-in is marked. A sign-in is marked only when no refresh can fix it
  # for the token the run has (`Login.rejectable?/3`), by the sign-in time of that token
  # and the database's clock.
  defp markable?(nil, _sealed_at, _now), do: true
  defp markable?(%Login{} = login, sealed_at, now), do: Login.rejectable?(login, sealed_at, now)

  # The rows of the keys whose value the run has (`current?/3`), written after their
  # values' rows are locked in the order of their ids, as `write_states/2` has it, with the
  # time the value was set. A sign-in's row is read after that lock, so a refresh, which
  # writes the value's row too, is either whole before the read or waits for this
  # transaction: a sign-in that a refresh can still fix (`Login.rejectable?/3`) is not
  # marked.
  defp write_rejections(rows, copies, sealed, provider) do
    ids = Enum.map(rows, & &1.secret_value_id)

    set =
      Repo.all(
        from v in Value,
          where: v.id in ^ids,
          order_by: v.id,
          lock: "FOR SHARE",
          select: {v.id, v.value_set_at}
      )
      |> Map.new()

    logins = if provider, do: Login.rows(provider, ids), else: %{}
    now = Login.db_now()

    kept =
      for row <- rows,
          current?(row, set, copies),
          markable?(logins[row.secret_value_id], sealed[row.secret_value_id], now),
          do: Map.put(row, :value_set_at, set[row.secret_value_id])

    if kept != [] do
      Repo.insert_all(Rejection, kept,
        on_conflict:
          from(r in Rejection,
            where:
              fragment("EXCLUDED.value_set_at IS DISTINCT FROM ?", r.value_set_at) or
                fragment("EXCLUDED.rejected_at > ?", r.rejected_at),
            update: [
              set: [
                rejected_at: fragment("EXCLUDED.rejected_at"),
                value_set_at: fragment("EXCLUDED.value_set_at"),
                updated_at: fragment("EXCLUDED.updated_at")
              ]
            ]
          ),
        conflict_target: [:secret_value_id]
      )
    end

    :ok
  end

  @doc """
  The rows of `Apiary.ModelKeys.Rejection` of the keys of `provider` that count, by the
  key's row id (`secret_values.id`): for a page, which keys need a new value.
  """
  @spec rejections(Connection.t()) :: %{Ecto.UUID.t() => Rejection.t()}
  def rejections(%Connection{secret_id: secret_id}) when is_binary(secret_id) do
    from(r in Rejection,
      as: :rejection,
      join: v in Value,
      as: :value,
      on: v.id == r.secret_value_id,
      where: v.secret_id == ^secret_id
    )
    |> Rejection.live()
    |> Repo.all()
    |> Map.new(&{&1.secret_value_id, &1})
  end

  def rejections(%Connection{}), do: %{}

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
