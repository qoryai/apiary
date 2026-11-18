defmodule Apiary.ModelKeys.Login do
  @moduledoc """
  The sign-in of a model key whose provider's API has `oauth_refresh` in its catalogue
  entry, such as an OpenAI subscription: the tokens that the provider's device sign-in
  (`Apiary.ModelKeys.DeviceSignIn`) returns. The key is still one value of the provider's
  secret (`Apiary.ModelKeys`). Its stored value is the document `from_tokens/3` makes,
  `{"version": 1, "access_token", "refresh_token"}`, encrypted like any other key value,
  and nothing else of the response is kept; an `id_token` is not stored.
  The row of this module has what the server needs to know about the sign-in without
  decrypting it: the account, when the access token expires, and whether the provider
  still accepts the refresh token.

  `from_tokens/3` reads the response and makes no network call. It trusts the TLS channel
  to the token address of the catalogue entry's `oauth_refresh`: the JWT payloads (the
  account id and the `exp`) are decoded and not signature-checked, because the server uses
  them only to name the account and to decide when to refresh. A response without a string
  for each of `access_token` and `refresh_token`, or without an account id at the
  catalogue's claim, is refused, and so is one whose access token and ID token have
  different account ids.

  `put/3` writes the row of a key's new login: `generation` 1, plus 1 for each sign-in
  over it, so a refresh that started before it can be dropped. The caller is
  `Apiary.Connections`, in the transaction that stores the value.

  Only this module reads the tokens (`tokens/2`): the secrets module's `reveal_key_and_set_at/2`
  refuses the key of such a provider with `{:error, :login}`, so a login is never sealed
  into a run as it is stored.

  ## The refresh

  `access_token/3` gives the access token of a key and refreshes it first when that is
  due, by the rule of `codex` (openai/codex at 2f5c413e,
  `codex-rs/login/src/auth/manager.rs:3660-3678`, constants at `:232-233`): before the
  access token's `exp`, and only for a token with no readable `exp` (`access_expires_at`
  is nil) 8 days after the last refresh (after the sign-in, for a login not yet
  refreshed). The lead before `exp` is 5 minutes 30 seconds for a run's request and 5
  minutes for the `:schedule` trigger, the sweep's: the gateway renews a run's token
  5 minutes before the `expires_at` it was given, and a request that arrives a few seconds
  before that would get the same token back, which makes the gateway call again 30
  seconds later. The sweep, a job every 6 hours, takes the logins more than 7 days after
  their last refresh, whatever their `exp`. A login is not refreshed again within 60
  seconds of a refresh: one whose new access token is already past its `exp`, or within
  the lead, would otherwise be called again by every run. A refresh is one call
  (`Apiary.ModelKeys.LoginRefresh`), and one at a time per login:

    1. The caller calls `Apiary.Access` with `model_key.refresh`. When that returns an
       error, as it does for an instance without the `secrets` feature, the refresh makes
       no call and writes no entry.
    2. On a node that is stopping (`:init.get_status/0` returns `{:stopping, _}`) the refresh
       takes no lease and makes no call: the caller gets the stored token while it is valid,
       else `:unavailable`. Otherwise it takes the login's lease, one conditional `UPDATE`
       of `lease_id` and
       `lease_until` (75 seconds, by the database's clock, `clock_timestamp()`) that
       succeeds only for a `signed_in` login with no live lease and no `retry_at` in the
       future. A lease past `lease_until` is taken over. The same transaction reads the
       key's value, so the tokens it sends are those of the `generation` the lease read.
    3. It checks again that the login is due: another process may have refreshed it
       since the caller looked, and then the caller releases the lease and returns the new
       token with no call.
    4. A task that is linked to no caller (it runs under the refresh's task supervisor)
       makes the call, with no transaction open, and then writes the outcome in one transaction,
       in the lock order of docs/access.md: the organisation `FOR SHARE`, the keys' secret
       `FOR UPDATE`, then the login's row. The caller waits for the task until its deadline
       (`wait:`); when the caller is killed or out of time, the task goes on and writes the
       result, and the next caller reads it.
    5. The result is written only if the row's `lease_id` and `generation` are the ones
       the refresh started from and the stored value's `value_set_at` is too (the guarded
       write of `Apiary.Secrets`). A new sign-in of the key meanwhile (a new
       `generation`), a key that was deleted, or a lease taken over drops the result, and
       the key keeps what it has. A key renamed meanwhile keeps the result: it is written
       under the name the key has when the outcome is written, so the rotated refresh
       token is not lost. A refresh changes no `value_set_at`, so the key's states and the
       runs' copies stay.
    6. The Activity page has an entry `model_key.refresh` (by the instance, in the
       organisation's trail, written after the outcome is stored; one that cannot be
       written is logged and costs nothing else) for a refresh that works, for the first
       failure of a streak (`failing_since` is nil), and for a refusal that stays. The
       failures that follow the first one while the streak is open leave no entry: the
       row has their count (`failures`) and the time of the last (`last_failure`). The
       refresh that works while a streak is open ends it and leaves the entry of a
       refresh that works. A new sign-in of the key ends the streak with no entry. A
       result that is dropped, and a new refresh token that could not be stored while the
       old one is still good, leave no entry and open no streak.

  A caller that does not get the lease while another process holds it reads the row every
  250 ms for up to 10 seconds and returns the new token when the lease ends. After a
  permanent refusal (`causes/0`) the login is `sign_in_needed` and no call is made until
  a new sign-in is stored. After a transient failure (a 5xx or 429, a timeout, a network
  error, an answer that is no refresh) `retry_at` is 30 seconds on, doubling for each
  failure in a row up to 10 minutes; the caller gets the old token while it is valid, else
  `{:error, :unavailable}`.

  A rotated refresh token that the key cannot store (a document past a value's size, a key
  that cannot be read, or a write that raises) is written once more at once, from the
  task's memory. When that fails too, the login is `sign_in_needed` with the cause
  `token_not_stored`, and no call is made with the stored refresh token, which the
  provider has replaced. The mark is written like the tokens, and logged when it fails;
  when even that cannot be written, the lease lapses after 75 seconds. Then, and when the
  node stops after the provider returned its response and before the write commits, the
  next refresh uses the stored, replaced refresh token. The provider accepted it in a check
  on 2026-11-18; if it no longer does, the login ends `sign_in_needed` with
  `refresh_token_reused`. A shutdown of the task supervisor (a deploy) does not stop the
  task at once: it traps exits, so it writes the result it has within 75 seconds (the lease,
  `lease_ms/0`), and the task that makes the request ends its request within 20 seconds. A
  call that the supervisor kills after that is no failure: the task counts none, writes no
  entry, clears the lease and returns `:unavailable`.
  """

  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias Apiary.Audit
  alias Apiary.Connections.Connection
  alias Apiary.Features
  alias Apiary.Kinds.{Provider, Providers}
  alias Apiary.ModelKeys.LoginRefresh
  alias Apiary.Organisations.Organisation
  alias Apiary.Repo
  alias Apiary.Secrets
  alias Apiary.Secrets.{Secret, Value}

  @typedoc "The row of a key's sign-in."
  @type t :: %__MODULE__{}

  defmodule Parsed do
    @moduledoc false
    # What `Apiary.ModelKeys.Login.from_tokens/3` reads from an answer. `document` has the
    # tokens, so `inspect/2` shows the account and the expiry alone.
    @derive {Inspect, only: [:account_id, :access_expires_at]}
    @enforce_keys [:document, :account_id, :access_expires_at]
    defstruct [:document, :account_id, :access_expires_at]
  end

  @typedoc "What `from_tokens/3` reads from an answer."
  @type parsed :: %Parsed{
          document: binary,
          account_id: String.t(),
          access_expires_at: DateTime.t()
        }

  @states ~w(signed_in sign_in_needed)
  # The causes of a sign-in that needs a new login: the provider's permanent refusals of a
  # refresh (the refresh token expired, was used already, or was invalidated; a 400
  # `invalid_grant`; a 401 from the refresh call, `refresh_unauthorized`, where
  # `unauthorized` is the model API's 401) and `token_not_stored`, the provider's answer
  # with a new refresh token that the key could not store. The check of `model_key_logins`
  # lists the same six.
  @causes ~w(refresh_token_expired refresh_token_reused refresh_token_invalidated
             invalid_grant refresh_unauthorized token_not_stored)

  # When a refresh is due: this long before the access token's `exp`, or this long after
  # the last refresh, as `codex` has it (`manager.rs:232-233`); the sweep's age is shorter.
  # A run's request refreshes earlier, `@run_lead_seconds` before the `exp` (`lead_seconds/1`).
  @lead_seconds 300
  @run_lead_seconds 330
  # The lease of a refresh and the time the task supervisor gives the refresh task to end
  # when the supervisor stops (`lease_ms/0`): the call's limit (`LoginRefresh.call_limit_ms/0`,
  # 15 seconds), three writes of at most 15 seconds each (the `Repo` timeout: the two tries of
  # the new tokens and the mark `token_not_stored`) and a margin of 15 seconds, 75 seconds.
  @write_ms 15_000
  @lease_margin_ms 15_000
  # The least time between a refresh and the next one (`decide/3`).
  @gap_seconds 60
  # The pages of logins that one pass of the sweep reads at most (`sweep_due/2`).
  @sweep_max_pages 20
  # Where the sweep goes on in this node's next pass (`sweep_due/1`).
  @sweep_cursor {__MODULE__, :sweep_cursor}
  @age_days 8
  @sweep_age_days 7
  @day 86_400
  @wait_ms 10_000
  @poll_ms 250
  @backoff_seconds 30
  @backoff_max_seconds 600

  @primary_key false
  @foreign_key_type :binary_id
  schema "model_key_logins" do
    field :secret_value_id, :binary_id, primary_key: true
    belongs_to :organisation, Apiary.Organisations.Organisation

    field :account_id, :string, redact: true
    field :access_expires_at, :utc_datetime_usec
    field :signed_in_at, :utc_datetime_usec
    field :refreshed_at, :utc_datetime_usec
    field :state, :string, default: "signed_in"
    field :sign_in_cause, :string
    field :failures, :integer, default: 0
    field :retry_at, :utc_datetime_usec
    field :last_failure, :utc_datetime_usec
    field :failing_since, :utc_datetime_usec
    field :generation, :integer, default: 1
    field :lease_id, :binary_id
    field :lease_until, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @doc "The states of a sign-in: `signed_in` and `sign_in_needed`."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc """
  The causes of a sign-in that needs a new one: the first five come from a permanent
  refusal of the provider (`Apiary.ModelKeys.LoginRefresh.call/3`), and `token_not_stored`
  is set by this module when a new sign-in could not be stored.
  """
  @spec causes() :: [String.t()]
  def causes, do: @causes

  @doc """
  Whether the keys of `provider`, a provider row or its catalogue name, are sign-ins: an
  API of its catalogue entry has `oauth_refresh`. False for a provider the catalogue no
  longer has.
  """
  @spec provider?(Connection.t() | String.t() | nil) :: boolean
  def provider?(%Connection{provider_kind: kind}), do: provider?(kind)

  def provider?(kind) when is_binary(kind) do
    case Providers.fetch(kind) do
      {:ok, %Provider{apis: apis}} -> Enum.any?(apis, &is_map(&1["oauth_refresh"]))
      :error -> false
    end
  end

  def provider?(_kind), do: false

  @doc """
  Reads the response of the provider's code exchange at the end of a device sign-in
  (`Apiary.ModelKeys.DeviceSignIn`): `response`, the JSON object with `access_token`,
  `refresh_token` and, as the provider sends them, `id_token` and `expires_in`.
  `account_claim` is the JSON pointer of the account id in the access token's payload,
  `auth.account_claim` of the catalogue entry's API. `{:ok, parsed}` with the document to
  store as the key's value, the account id and when the access token expires;
  `{:error, :no_account}` for a response that is a sign-in but has no account id at the
  claim; `{:error, :invalid}` for any other response: one without a refresh token or a
  printable access token, or with different account ids in the access token and the ID
  token. It makes no network call, never raises, and its return value contains nothing of
  `response`.

  The expiry is the access token's `exp`, else `expires_in` seconds after `now`, else nil.
  Either is used only when it is 1 second to 366 days after `now`; a value outside that
  range is unreadable, as a value that is no number is.
  """
  @spec from_tokens(term, String.t() | nil, DateTime.t()) ::
          {:ok, parsed} | {:error, :invalid | :no_account}
  def from_tokens(answer, account_claim, now \\ DateTime.utc_now())

  def from_tokens(%{} = response, account_claim, now) do
    with {:ok, refresh_token} <- string(response, "refresh_token"),
         {:ok, access_token} <- string(response, "access_token"),
         true <- String.match?(access_token, ~r/\A[!-~]+\z/),
         {:ok, account_id} <- account_id(response, account_claim, access_token),
         document = document(access_token, refresh_token),
         true <- byte_size(document) <= Value.value_max() do
      {:ok,
       %Parsed{
         document: document,
         account_id: account_id,
         access_expires_at: expires_at(access_token, response["expires_in"], now)
       }}
    else
      :no_account -> {:error, :no_account}
      _refused -> {:error, :invalid}
    end
  end

  def from_tokens(_answer, _claim, _now), do: {:error, :invalid}

  defp string(map, name) do
    case map do
      %{^name => value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> :error
    end
  end

  # The account id goes into a request header: 1 to 255 printable ASCII characters, no
  # space. `\z`, not `$`, so a line feed at the end is refused too.
  defp account_id?(account_id), do: String.match?(account_id, ~r/\A[!-~]{1,255}\z/)

  # The id in the access token's payload at the JSON pointer `claim`, else in the id
  # token's. When both have one, the two must be the same.
  defp account_id(response, claim, access_token) when is_binary(claim) do
    ids =
      for token <- [access_token, response["id_token"]],
          is_binary(token),
          {:ok, payload} <- [payload(token)],
          id when is_binary(id) <- [pointer(payload, claim)],
          do: id

    case Enum.uniq(ids) do
      [] -> :no_account
      [id] -> if account_id?(id), do: {:ok, id}, else: :error
      _different -> :error
    end
  end

  defp account_id(_response, _claim, _access_token), do: :error

  # The value at the JSON pointer (RFC 6901) `claim` of `payload`, nil where it has none.
  defp pointer(payload, "/" <> claim) do
    claim
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce_while(payload, fn
      key, %{} = map -> {:cont, Map.get(map, key)}
      _key, _other -> {:halt, nil}
    end)
  end

  defp pointer(_payload, _claim), do: nil

  defp payload(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _other -> :error
    end
  end

  defp expires_at(access_token, expires_in, now) do
    case bounded_expiry(access_token, now) do
      {:ok, at} ->
        at

      {:error, :invalid} ->
        with {:ok, seconds} <- lifetime(expires_in) do
          at = DateTime.add(now, seconds, :second)
          %{at | microsecond: {elem(at.microsecond, 0), 6}}
        else
          _unreadable -> nil
        end
    end
  end

  # The most a token may live, from `now`: 366 days, so that no sum of a time and a number
  # of seconds from a response goes out of the range of `DateTime`.
  @lifetime_max 366 * 86_400

  defp lifetime(seconds) when is_integer(seconds) and seconds >= 1 and seconds <= @lifetime_max,
    do: {:ok, seconds}

  defp lifetime(_seconds), do: {:error, :invalid}

  # The `exp` of a JWT's payload as a time, when it is 1 second to 366 days after `now`.
  # The signature is not checked: the time only decides when to refresh.
  defp bounded_expiry(token, now) do
    with {:ok, %{"exp" => exp}} when is_integer(exp) <- payload(token),
         {:ok, _seconds} <- lifetime(exp - DateTime.to_unix(now)) do
      expiry(token)
    else
      _other -> {:error, :invalid}
    end
  end

  # The `exp` of a JWT's payload, in whole seconds since 1970, as a time; the refresh reads
  # a stored token's with this, so it has no bound.
  defp expiry(token) do
    with {:ok, %{"exp" => exp}} when is_integer(exp) <- payload(token),
         {:ok, at} <- DateTime.from_unix(exp) do
      {:ok, %{at | microsecond: {0, 6}}}
    else
      _other -> {:error, :invalid}
    end
  end

  defp document(access_token, refresh_token) do
    Jason.encode!(%{
      "version" => 1,
      "access_token" => access_token,
      "refresh_token" => refresh_token
    })
  end

  @doc """
  Writes the row of the key `value`'s new login `parsed`, in the caller's transaction: the
  state `signed_in`, no failure, no lease, `refreshed_at` nil and `signed_in_at` `now`;
  `generation` is 1 for a new key, and the key's plus 1 for a sign-in over another.
  `{:ok, row}`.
  """
  @spec put(Value.t(), parsed, DateTime.t()) :: {:ok, t} | {:error, Ecto.Changeset.t()}
  def put(%Value{id: id, organisation_id: organisation_id}, parsed, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :microsecond)

    fresh = [
      account_id: parsed.account_id,
      access_expires_at: parsed.access_expires_at,
      signed_in_at: now,
      refreshed_at: nil,
      state: "signed_in",
      sign_in_cause: nil,
      failures: 0,
      retry_at: nil,
      last_failure: nil,
      failing_since: nil,
      lease_id: nil,
      lease_until: nil,
      updated_at: now
    ]

    Repo.insert(
      struct!(__MODULE__, [secret_value_id: id, organisation_id: organisation_id] ++ fresh),
      on_conflict: [set: fresh, inc: [generation: 1]],
      conflict_target: :secret_value_id,
      returning: true
    )
  end

  @doc """
  The sign-ins of the keys of `provider`, by the key's row id (`secret_values.id`): none
  for a provider whose keys are not sign-ins.
  """
  @spec by_key(Connection.t()) :: %{Ecto.UUID.t() => t}
  def by_key(%Connection{secret_id: secret_id} = provider) when is_binary(secret_id) do
    if provider?(provider) do
      Repo.all(
        from l in __MODULE__,
          join: v in Value,
          on: v.id == l.secret_value_id,
          where: v.secret_id == ^secret_id
      )
      |> Map.new(&{&1.secret_value_id, &1})
    else
      %{}
    end
  end

  def by_key(%Connection{}), do: %{}

  @doc """
  The tokens of the key `secret_value_id` of `provider`, decrypted for the refresh and for
  nothing else: `{:ok, %{access_token:, refresh_token:}}`, or `{:error, reason}`
  as the secrets module's `reveal_login/2` returns, with `:invalid` for a stored value that is
  not the document `from_tokens/3` makes. The tokens go to the provider's token endpoint and
  nowhere else: not into a log, an assign, an error or an audit entry.
  """
  @spec tokens(Connection.t(), Ecto.UUID.t()) ::
          {:ok, %{access_token: String.t(), refresh_token: String.t()}}
          | {:error, :not_found | :unavailable | :invalid}
  def tokens(%Connection{} = provider, secret_value_id) do
    with {:ok, plaintext} <- Secrets.reveal_login(provider, secret_value_id),
         do: read_document(plaintext)
  end

  @doc """
  Whether `text` is a stored login's document, as `from_tokens/3` makes it: a JSON object with
  `version` 1 and a non-empty string for each of `access_token` and `refresh_token`.
  the guarded write of `Apiary.Secrets` returns an error for any other text.
  """
  @spec document?(term) :: boolean
  def document?(text), do: match?({:ok, _tokens}, read_document(text))

  defp read_document(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok,
       %{
         "version" => 1,
         "access_token" => access_token,
         "refresh_token" => refresh_token
       }}
      when is_binary(access_token) and access_token != "" and is_binary(refresh_token) and
             refresh_token != "" ->
        {:ok, %{access_token: access_token, refresh_token: refresh_token}}

      _other ->
        {:error, :invalid}
    end
  end

  defp read_document(_text), do: {:error, :invalid}

  ## The refresh

  @typedoc """
  What starts a refresh: `:schedule`, the sweep, or `{:run, public_id}`, the run that
  needs the key's access token. The audit entry of the call contains it.
  """
  @type trigger :: :schedule | {:run, String.t()}

  @doc """
  The access token of the key `secret_value_id` of `provider` and when it expires (nil for
  a token with no readable `exp`),
  refreshed first when that is due (see the module's documentation): `{:ok, token,
  expires_at}`, or `{:error, reason}`:

    * `:sign_in_needed`: the key needs a new sign-in, now or earlier, because the provider
      rejected the refresh for good or Qory Apiary could not store the new sign-in
      (`token_not_stored`), and no call is made until a new sign-in is stored;
    * `:unavailable`: the access token has expired and could not be refreshed, because a
      call failed for a reason that may pass, another caller's refresh did not end in
      time, `Apiary.Access` does not allow the refresh (`model_key.refresh`), the node is
      stopping (no refresh starts then), or the key cannot be read;
    * `:not_found`: a key that is gone, or that is no login.

  `opts`: `trigger:` (required, `t:trigger/0`), `wait:`, how long in milliseconds a caller
  waits for a refresh, whether another caller's or the call it makes itself (10,000), and
  `poll:`, how often it looks (250). When the wait ends first, the caller gets the stored
  token while it is valid, else `{:error, :unavailable}`, and the call goes on and stores
  its result. `now:` fixes the time the due decision reads, for a test. The token is for the
  caller's one use: it goes to a run's secrets request and nowhere else.
  """
  @spec access_token(Connection.t(), Ecto.UUID.t(), keyword) ::
          {:ok, String.t(), DateTime.t() | nil}
          | {:error, :sign_in_needed | :unavailable | :not_found}
  def access_token(%Connection{} = provider, secret_value_id, opts) do
    trigger = Keyword.fetch!(opts, :trigger)

    unless trigger == :schedule or match?({:run, id} when is_binary(id), trigger) do
      raise ArgumentError, "the trigger of a refresh is :schedule or {:run, public_id}"
    end

    step(%{
      provider: provider,
      id: secret_value_id,
      trigger: trigger,
      deadline: System.monotonic_time(:millisecond) + Keyword.get(opts, :wait, @wait_ms),
      poll: Keyword.get(opts, :poll, @poll_ms),
      now: Keyword.get(opts, :now),
      allowed: false
    })
  end

  defp lease_ms, do: LoginRefresh.call_limit_ms() + 3 * @write_ms + @lease_margin_ms

  @doc false
  # The lease of a refresh in seconds (`lease_ms/0`), for a test.
  @spec lease_seconds() :: pos_integer
  def lease_seconds, do: div(lease_ms(), 1000)

  # Whether the node is stopping: `:init.get_status/0` returns `{:stopping, _}` from the moment
  # `:init.stop/0` runs (what `System.stop/0` and a SIGTERM to the release call), before any
  # application stops. A deploy ends the node at 40 seconds after the SIGTERM at the latest
  # (the endpoint stops for 20 seconds, Oban for 15, then the process is killed), so a
  # refresh that starts during the stop can be killed before its call and its writes end
  # (up to 90 seconds). A stopping node therefore starts none.
  # `stopping:` in this module's settings is a function for a test.
  defp stopping? do
    case Application.get_env(:apiary, __MODULE__, [])[:stopping] do
      fun when is_function(fun, 0) -> fun.()
      _none -> match?({:stopping, _}, :init.get_status())
    end
  end

  @doc """
  The keys whose sign-in the sweep refreshes: at most `limit` of them, oldest first, each
  as `{provider, secret_value_id}`, from `sweep_pass/3`. A key is one whose login is
  `signed_in`, was last refreshed (signed in, when it never was) more than 7 days ago, has
  no live lease and no `retry_at` in the future, and whose organisation `Apiary.Access`
  lets the instance refresh in (`model_key.refresh`: not marked for deletion, `secrets`
  on).

  A query cannot call `Apiary.Access`, so a pass reads the due logins page by page and
  skips those of an organisation that Access does not allow. A pass reads at most 20 pages
  and starts after the last login that the last pass of this node read. Logins of refused
  organisations ahead of an allowed login then cost at most 20 queries in a pass, and the
  allowed login is reached after `ceil(refused logins / (20 * limit))` passes at most. A
  pass that reaches the end of the due logins before it has `limit` keys goes on from the
  oldest login, up to the login it started after. The position is kept in memory, in
  `:persistent_term`, on each node, and is lost when the node restarts: the next pass then
  starts at the oldest login. The setting `sweep_position: false` of this module disables
  it, for tests. A node that is stopping returns no keys (`stopping?/0`).
  """
  @spec sweep_due(pos_integer) :: [{Connection.t(), Ecto.UUID.t()}]
  def sweep_due(limit) when is_integer(limit) and limit > 0 do
    if Features.on?(:secrets) and not stopping?() do
      if Application.get_env(:apiary, __MODULE__, [])[:sweep_position] == false do
        sweep_pass(limit, nil) |> elem(0)
      else
        {kept, cursor} = sweep_pass(limit, :persistent_term.get(@sweep_cursor, nil))
        store_sweep_cursor(cursor)
        kept
      end
    else
      []
    end
  end

  defp store_sweep_cursor(nil), do: :persistent_term.erase(@sweep_cursor) && :ok
  defp store_sweep_cursor(cursor), do: :persistent_term.put(@sweep_cursor, cursor)

  @doc """
  One pass of the sweep, from `cursor` (nil: the oldest login): `{kept, cursor}`, the keys
  as `sweep_due/1` has them and the position after the last login the pass read (nil when
  no login is left after it).

  The logins are read `limit` at a time, each page after the last login of the one before
  (its time of last refresh, then its key's id), so a login that changes between two pages
  is neither skipped nor listed twice. The pass stops when `limit` keys are kept, when a
  page is short and no part of the list is left to wrap to, or after `max_pages` pages (20):
  then it logs a warning with the number of logins read and the cap. A pass that starts
  after `cursor` and reaches the end of the list with fewer than `limit` keys goes on from
  the oldest login, up to `cursor`, and then returns no cursor. `after_page:` is a function
  that the pass calls with the number of each page after it is read, for a test.
  """
  @spec sweep_pass(pos_integer, {DateTime.t(), Ecto.UUID.t()} | nil, keyword) ::
          {[{Connection.t(), Ecto.UUID.t()}], {DateTime.t(), Ecto.UUID.t()} | nil}
  def sweep_pass(limit, cursor, opts \\ []) when is_integer(limit) and limit > 0 do
    max_pages = Keyword.get(opts, :max_pages, @sweep_max_pages)

    sweep_page(
      %{
        limit: limit,
        max_pages: max_pages,
        pages_left: max_pages,
        start: cursor,
        wrapped: false,
        number: 0,
        read: 0,
        after_page: Keyword.get(opts, :after_page, fn _number -> :ok end)
      },
      cursor,
      %{},
      []
    )
  end

  # Reads one page after `cursor` and keeps the logins of the organisations that may be
  # refreshed (`allowed` maps an organisation id to the result of the Access check made for it
  # so far in this pass).
  defp sweep_page(%{pages_left: 0} = pass, cursor, _allowed, kept) do
    Logger.warning(
      "model key sign-in sweep: stopped after #{pass.read} logins read in #{pass.max_pages} " <>
        "pages, the most a pass reads; the next pass goes on after them"
    )

    {Enum.reverse(kept), cursor}
  end

  defp sweep_page(pass, cursor, allowed, kept) do
    page = sweep_candidates(pass.limit, cursor, if(pass.wrapped, do: pass.start))

    pass = %{
      pass
      | pages_left: pass.pages_left - 1,
        number: pass.number + 1,
        read: pass.read + length(page)
    }

    pass.after_page.(pass.number)

    {kept, allowed, filled_by} =
      Enum.reduce_while(page, {kept, allowed, nil}, fn {{provider, id}, _at} = candidate,
                                                       {kept, allowed, _filled_by} ->
        organisation_id = provider.organisation_id

        allowed =
          Map.put_new_lazy(allowed, organisation_id, fn ->
            organisation_allowed?(organisation_id)
          end)

        # A login that changed after its page was read can come up again, later.
        keep? = allowed[organisation_id] and not List.keymember?(kept, id, 1)
        kept = if keep?, do: [{provider, id} | kept], else: kept

        if length(kept) >= pass.limit,
          do: {:halt, {kept, allowed, candidate}},
          else: {:cont, {kept, allowed, nil}}
      end)

    cond do
      filled_by ->
        {Enum.reverse(kept), cursor(filled_by)}

      length(page) < pass.limit and pass.start != nil and not pass.wrapped ->
        sweep_page(%{pass | wrapped: true}, nil, allowed, kept)

      length(page) < pass.limit ->
        {Enum.reverse(kept), nil}

      true ->
        sweep_page(pass, page |> List.last() |> cursor(), allowed, kept)
    end
  end

  defp cursor({{_provider, id}, at}), do: {at, id}

  @doc false
  # `limit` due logins after `cursor` (nil: from the start), as `{{provider, id}, at}`, `at`
  # being the time the order reads: the last refresh, else the sign-in.
  # `until`, when it is not nil, is the position of the last login that may be read.
  @spec sweep_candidates(
          pos_integer,
          {DateTime.t(), Ecto.UUID.t()} | nil,
          {DateTime.t(), Ecto.UUID.t()} | nil
        ) :: [{{Connection.t(), Ecto.UUID.t()}, DateTime.t()}]
  def sweep_candidates(limit, cursor, until \\ nil) do
    oldest = DateTime.add(db_now(), -@sweep_age_days * @day)

    Repo.all(
      from l in __MODULE__,
        join: v in Value,
        on: v.id == l.secret_value_id,
        join: c in Connection,
        on: c.secret_id == v.secret_id and c.organisation_id == l.organisation_id,
        join: o in Organisation,
        on: o.id == l.organisation_id,
        where:
          l.state == "signed_in" and not is_nil(c.provider_kind) and
            is_nil(o.deletion_marked_at) and
            coalesce(l.refreshed_at, l.signed_in_at) < ^oldest and
            (is_nil(l.retry_at) or l.retry_at < fragment("clock_timestamp()")) and
            (is_nil(l.lease_until) or l.lease_until < fragment("clock_timestamp()")),
        where: ^after_cursor(cursor),
        where: ^up_to(until),
        order_by: [asc: coalesce(l.refreshed_at, l.signed_in_at), asc: l.secret_value_id],
        limit: ^limit,
        select: {{c, l.secret_value_id}, coalesce(l.refreshed_at, l.signed_in_at)}
    )
  end

  defp after_cursor(nil), do: dynamic(true)

  defp after_cursor({at, id}) do
    dynamic(
      [l],
      coalesce(l.refreshed_at, l.signed_in_at) > ^at or
        (coalesce(l.refreshed_at, l.signed_in_at) == ^at and l.secret_value_id > ^id)
    )
  end

  defp up_to(nil), do: dynamic(true)

  defp up_to({at, id}) do
    dynamic(
      [l],
      coalesce(l.refreshed_at, l.signed_in_at) < ^at or
        (coalesce(l.refreshed_at, l.signed_in_at) == ^at and l.secret_value_id <= ^id)
    )
  end

  @doc false
  # Whether `Apiary.Access` lets the instance refresh a sign-in of the provider's
  # organisation (`model_key.refresh`).
  @spec refresh_allowed?(Connection.t()) :: boolean
  def refresh_allowed?(%Connection{organisation_id: id}), do: organisation_allowed?(id)

  defp organisation_allowed?(id) do
    case Repo.get(Organisation, id) do
      %Organisation{} = organisation ->
        Access.check(Scope.for_instance(organisation), :"model_key.refresh", organisation) == :ok

      nil ->
        false
    end
  end

  # Whether the sign-in is due for a refresh now, and the `refresh_reason` to send, by the
  # rule of `codex`: openai/codex at 2f5c413e, `codex-rs/login/src/auth/manager.rs`,
  # `proactive_refresh_reason` (lines 3660-3678) and its constants (lines 232-233). With an
  # access token whose `exp` can be read, the sign-in is due when that expiry is within the
  # trigger's lead (`proactive_expiry`, see `lead_seconds/1`), and for no other reason: an
  # `exp` far ahead is not refreshed after 8 days. Only with no readable `exp`
  # (`access_expires_at` is nil) is it due when the last refresh (the sign-in, before the
  # first) is more than 8 days old (`scheduled`). A `:schedule` trigger, the sweep's, is also
  # due when the last refresh is more than 7 days old, whatever the `exp`, with `scheduled`.
  defp due_reason(%__MODULE__{access_expires_at: %DateTime{} = expires_at} = row, now, trigger) do
    cond do
      DateTime.compare(expires_at, DateTime.add(now, lead_seconds(trigger))) != :gt ->
        "proactive_expiry"

      trigger == :schedule and older_than?(row, now, @sweep_age_days) ->
        "scheduled"

      true ->
        nil
    end
  end

  defp due_reason(%__MODULE__{access_expires_at: nil} = row, now, trigger) do
    days = if trigger == :schedule, do: @sweep_age_days, else: @age_days
    if older_than?(row, now, days), do: "scheduled"
  end

  # How long before the access token's `exp` a refresh is due. The sweep and the
  # `:schedule` trigger refresh within 5 minutes, as `codex` does. A run's request refreshes
  # within 5 minutes 30 seconds: the gateway renews a run's token 5 minutes before the
  # `expires_at` it was given (forager `gateway/internal/run/renew.go:210-256`), and a
  # request that arrives a few seconds before that time would get the same token back, so
  # the gateway would call once more 30 seconds later.
  defp lead_seconds(:schedule), do: @lead_seconds
  defp lead_seconds({:run, _id}), do: @run_lead_seconds

  defp older_than?(%__MODULE__{} = row, now, days) do
    last = row.refreshed_at || row.signed_in_at
    DateTime.compare(last, DateTime.add(now, -days * @day)) == :lt
  end

  # What a caller does with the sign-in: `:fresh` (no refresh is due), `{:due, reason}`, or
  # `:held`, which is due but follows a refresh less than 60 seconds ago. A refresh that
  # returns an access token already past its `exp`, or within the lead, would otherwise be
  # due again at once, and every run would call the provider; the gap keeps it to one call a
  # minute, and a caller inside it gets the stored token while it is valid, as it does while
  # a `retry_at` holds. A login not refreshed yet (just signed in) is never held.
  defp decide(%__MODULE__{} = row, now, trigger) do
    case due_reason(row, now, trigger) do
      nil -> :fresh
      reason -> if recently_refreshed?(row, now), do: :held, else: {:due, reason}
    end
  end

  defp recently_refreshed?(%__MODULE__{refreshed_at: nil}, _now), do: false

  defp recently_refreshed?(%__MODULE__{refreshed_at: refreshed_at}, now),
    do: DateTime.compare(refreshed_at, DateTime.add(now, -@gap_seconds)) == :gt

  # The database's clock, which moves inside a transaction too (`now()` does not), and is
  # the one clock of every node.
  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  # The time the caller's due decisions read: the `now:` option, which a test sets to fix
  # the clock, else the database's. The lease, the lease's end and `retry_at` always read the
  # database's.
  defp now(%{now: %DateTime{} = now}), do: now
  defp now(_ctx), do: db_now()

  defp step(ctx) do
    case load(ctx) do
      nil ->
        {:error, :not_found}

      %__MODULE__{state: "sign_in_needed"} ->
        {:error, :sign_in_needed}

      %__MODULE__{} = row ->
        now = now(ctx)

        case decide(row, now, ctx.trigger) do
          :fresh -> serve(ctx)
          :held -> while_valid(serve(ctx), now)
          {:due, _reason} -> refresh_allowed(ctx)
        end
    end
  end

  # Calls `Apiary.Access` to check whether the instance may refresh a sign-in of the
  # provider's organisation (`model_key.refresh`, which needs the `secrets` feature), before
  # the lease is taken. When Access does not allow it, no call is made and no entry is
  # written, and the caller gets the stored token while it is valid.
  # `ctx.allowed` is set once Access allows it, so a caller that polls for another's refresh
  # calls Access once, not at each poll.
  defp refresh_allowed(%{allowed: true} = ctx), do: lease(ctx)

  defp refresh_allowed(ctx) do
    if refresh_allowed?(ctx.provider),
      do: lease(%{ctx | allowed: true}),
      else: while_valid(serve(ctx), now(ctx))
  end

  # The row of the key's sign-in, if the key is a value of the provider's secret.
  defp load(%{provider: %Connection{secret_id: secret_id}, id: id}) when is_binary(secret_id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.one(
        from l in __MODULE__,
          join: v in Value,
          on: v.id == l.secret_value_id,
          where: l.secret_value_id == ^id and v.secret_id == ^secret_id
      )
    else
      :error -> nil
    end
  end

  defp load(_ctx), do: nil

  # The access token as stored, with the expiry its `exp` gives.
  defp serve(%{provider: provider, id: id}) do
    case tokens(provider, id) do
      {:ok, %{access_token: token}} -> served(token)
      {:error, :not_found} -> {:error, :not_found}
      {:error, _unavailable_or_invalid} -> {:error, :unavailable}
    end
  end

  # A token with no readable `exp` has no expiry: nil.
  defp served(token) do
    case expiry(token) do
      {:ok, expires_at} -> {:ok, token, expires_at}
      {:error, _invalid} -> {:ok, token, nil}
    end
  end

  # The stored token while it has not expired (one with no expiry has not), else
  # `:unavailable`.
  defp while_valid(result, now) do
    case result do
      {:ok, _token, nil} = ok ->
        ok

      {:ok, _token, expires_at} = ok ->
        if DateTime.compare(expires_at, now) == :gt, do: ok, else: {:error, :unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## The lease

  # A node that is stopping takes no lease and makes no call (`stopping?/0`); the caller gets
  # the stored token while it is valid, else `:unavailable`, as when Access does not allow the
  # refresh.
  defp lease(ctx) do
    if stopping?() do
      while_valid(serve(ctx), now(ctx))
    else
      case take_lease(ctx) do
        {:ok, leased} -> refresh(ctx, leased)
        :none -> wait(ctx)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # One conditional UPDATE takes the lease, and the same transaction reads the key's
  # value, so that the generation the lease returns and the tokens belong together: a
  # new sign-in of the key waits for the login's row until this transaction ends, and one
  # that committed before the UPDATE is read by it.
  defp take_lease(%{provider: %Connection{secret_id: secret_id} = provider, id: id})
       when is_binary(secret_id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      lease_id = Ecto.UUID.generate()

      query =
        from l in __MODULE__,
          where:
            l.secret_value_id in subquery(
              from v in Value, where: v.id == ^id and v.secret_id == ^secret_id, select: v.id
            ) and l.state == "signed_in" and
              (is_nil(l.lease_until) or l.lease_until < fragment("clock_timestamp()")) and
              (is_nil(l.retry_at) or l.retry_at < fragment("clock_timestamp()")),
          update: [
            set: [
              lease_id: ^lease_id,
              lease_until:
                fragment("clock_timestamp() + ? * interval '1 second'", ^lease_seconds())
            ]
          ],
          select: l

      result =
        Repo.transact(fn ->
          case Repo.update_all(query, []) do
            {1, [row]} -> read_leased(provider, id, row, lease_id)
            {0, []} -> {:ok, :none}
          end
        end)

      case result do
        {:ok, :none} -> :none
        {:ok, leased} -> {:ok, leased}
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  defp take_lease(_ctx), do: {:error, :not_found}

  defp read_leased(provider, id, row, lease_id) do
    with {:ok, plaintext, snapshot} <- Secrets.reveal_login_snapshot(provider, id),
         {:ok, tokens} <- read_document(plaintext) do
      {:ok, %{row: row, lease_id: lease_id, tokens: tokens, snapshot: snapshot}}
    else
      {:error, :not_found} -> Repo.rollback(:not_found)
      {:error, _unavailable_or_invalid} -> Repo.rollback(:unavailable)
    end
  end

  defp release(%{id: id}, %{lease_id: lease_id}) do
    Repo.update_all(
      from(l in __MODULE__, where: l.secret_value_id == ^id and l.lease_id == ^lease_id),
      set: [lease_id: nil, lease_until: nil]
    )

    :ok
  end

  # The caller has the lease. Another process may have refreshed since the caller found the
  # login due, and then the new token is returned with no call.
  defp refresh(ctx, %{row: row, tokens: tokens} = leased) do
    now = now(ctx)

    case decide(row, now, ctx.trigger) do
      :fresh ->
        :ok = release(ctx, leased)
        served(tokens.access_token)

      :held ->
        :ok = release(ctx, leased)
        while_valid(served(tokens.access_token), now)

      {:due, reason} ->
        unlinked(ctx, leased, reason)
    end
  end

  # The call and the write of its outcome run together in one task that is linked to no
  # caller (it runs under `Apiary.ModelKeys.LoginRefresh.supervisor/0`), so that the rotated
  # refresh token is stored even when the caller is gone: killed, or out of time. The caller
  # waits for the task until its deadline (`wait:`), and then returns the old token while it
  # is valid, else `:unavailable`; the task goes on, commits, and the next caller reads
  # the new token. The lease (75 seconds) outlives the call (15 seconds at most) and its
  # writes.
  defp unlinked(ctx, leased, reason) do
    task =
      Task.Supervisor.async_nolink(
        LoginRefresh.supervisor(),
        fn ->
          # The stop signal of the supervisor (a deploy) is then a message in the task's
          # mailbox, and the task writes the result it has within `lease_ms/0`.
          Process.flag(:trap_exit, true)
          call_and_commit(ctx, leased, reason)
        end,
        shutdown: lease_ms()
      )

    case Task.yield(task, remaining(ctx)) || Task.ignore(task) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :unavailable}
      nil -> while_valid(served(leased.tokens.access_token), db_now())
    end
  end

  # The task's work. A failure of the write is caught here and logged by its kind alone: the
  # task's crash report would carry its arguments, which hold the tokens.
  defp call_and_commit(ctx, leased, reason) do
    case LoginRefresh.call(oauth_refresh(ctx.provider), leased.tokens.refresh_token, reason) do
      # A deploy stopped the call: no failure is counted and no entry is written. The lease
      # is cleared, so that the next caller does not wait for it to lapse.
      :shutdown ->
        :ok = release(ctx, leased)
        {:error, :unavailable}

      result ->
        finish(ctx, leased, reason, result)
    end
  rescue
    exception ->
      Logger.error("model key sign-in refresh failed: #{inspect(exception.__struct__)}")
      {:error, :unavailable}
  catch
    kind, _reason ->
      Logger.error("model key sign-in refresh failed: #{inspect(kind)}")
      {:error, :unavailable}
  end

  defp finish(ctx, leased, reason, result) do
    case commit(ctx, leased, reason, result) do
      {:refreshed, token, expires_at} -> {:ok, token, expires_at}
      :sign_in_needed -> {:error, :sign_in_needed}
      :failed -> while_valid(served(leased.tokens.access_token), db_now())
      # What the key has now: the new sign-in's token stored since, or the old one while it
      # is valid. No second call, whose refresh token the first used.
      :dropped -> while_valid(serve(ctx), db_now())
    end
  end

  defp remaining(%{deadline: deadline}),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  # The `oauth_refresh` of the provider's catalogue entry: its token endpoint and client id,
  # from the vendored description alone.
  defp oauth_refresh(%Connection{provider_kind: kind}) do
    with {:ok, %Provider{apis: apis}} <- Providers.fetch(kind),
         %{"oauth_refresh" => %{} = refresh} <- Enum.find(apis, &is_map(&1["oauth_refresh"])) do
      refresh
    else
      _none -> nil
    end
  end

  ## A caller that did not get the lease

  # Another process holds the lease, or the login is not due any more, or a failure set
  # `retry_at`. The caller reads the row again every `poll` ms until `deadline`.
  defp wait(ctx) do
    now = now(ctx)
    database_now = db_now()

    case load(ctx) do
      nil ->
        {:error, :not_found}

      %__MODULE__{state: "sign_in_needed"} ->
        {:error, :sign_in_needed}

      %__MODULE__{} = row ->
        case decide(row, now, ctx.trigger) do
          :fresh -> serve(ctx)
          :held -> while_valid(serve(ctx), now)
          {:due, _reason} -> wait_for_lease(ctx, row, now, database_now)
        end
    end
  end

  defp wait_for_lease(ctx, row, now, database_now) do
    cond do
      future?(row.retry_at, database_now) -> while_valid(serve(ctx), now)
      time_left?(ctx) -> poll(ctx)
      true -> while_valid(serve(ctx), now)
    end
  end

  defp poll(ctx) do
    Process.sleep(ctx.poll)
    step(ctx)
  end

  defp future?(nil, _now), do: false
  defp future?(at, now), do: DateTime.compare(at, now) == :gt
  defp time_left?(%{deadline: deadline}), do: System.monotonic_time(:millisecond) < deadline

  ## Writing the outcome

  # The outcome of the call in one transaction, in the lock order of docs/access.md: the
  # organisation `FOR SHARE`, the keys' secret `FOR UPDATE`, then the login's row. It
  # returns `{:refreshed, token, expires_at}`, `:sign_in_needed`, `:failed` (the old token
  # stays), or `:dropped`: the lease is not the caller's any more (a new sign-in over the
  # key clears it, or it lapsed and was taken over), a value was stored over the key since
  # the refresh started, or the key or its organisation is gone. The entry of the call is
  # written after the transaction, and best effort (`record/2`): a refresh token that the
  # provider rotated is in the key before any entry is tried. A write of a rotated token
  # that fails twice leaves the login `sign_in_needed` with the cause `token_not_stored`.
  defp commit(ctx, leased, reason, result) do
    if rotated?(result) do
      # The provider has replaced the stored refresh token: the new one is in `result`, in this
      # process, and nowhere else. A write that fails, or raises, is tried once more at
      # once; if that fails too, the login needs a new sign-in (`token_not_stored`).
      with :store_failed <- attempt(ctx, leased, reason, result),
           :store_failed <- attempt(ctx, leased, reason, result),
           :store_failed <- attempt(ctx, leased, reason, {:permanent, "token_not_stored"}) do
        # Not even the mark could be written (the database is down). The login stays
        # `signed_in` with the lease, which lapses after 75 seconds. The next refresh then
        # uses the stored, replaced refresh token; the provider accepted it in a check on
        # 2026-11-18, and if it no longer does, the login ends `sign_in_needed` with
        # `refresh_token_reused`. The caller gets the stored access token while it is valid.
        :failed
      end
    else
      write_outcome(ctx, leased, reason, result)
    end
  end

  defp rotated?({:ok, %{refresh_token: refresh_token}}), do: is_binary(refresh_token)
  defp rotated?(_result), do: false

  # One try of the write of a rotated token: the outcome, or `:store_failed` for a store that
  # returned an error or a write that raised. The exception is logged by its kind alone, as
  # its message and stack may contain the tokens.
  defp attempt(ctx, leased, reason, result) do
    write_outcome(ctx, leased, reason, result)
  rescue
    exception ->
      Logger.error(
        "model key sign-in refresh: the write failed: #{inspect(exception.__struct__)}"
      )

      :store_failed
  catch
    kind, _reason ->
      Logger.error("model key sign-in refresh: the write failed: #{inspect(kind)}")
      :store_failed
  end

  defp write_outcome(ctx, leased, reason, result) do
    {:ok, {outcome, entry}} =
      Repo.transact(fn ->
        case lock_organisation(ctx.provider) do
          nil ->
            {:ok, {:dropped, nil}}

          organisation ->
            lock_secret(ctx.provider)
            row = lock_login(ctx.id)
            now = db_now()

            # The key's name now, which a rename while the call ran has changed, for the
            # entry; the lease's name only for a key that is gone.
            value_id =
              Secrets.login_value_id(ctx.provider, ctx.id) || leased.snapshot.value_id

            write = %{
              ctx: ctx,
              leased: leased,
              reason: reason,
              organisation: organisation,
              value_id: value_id
            }

            if ours?(row, leased),
              do: {:ok, settle(write, row, result, now)},
              else: {:ok, dropped(write, nil)}
        end
      end)

    record(ctx, entry)
    outcome
  end

  defp ours?(%__MODULE__{} = row, %{lease_id: lease_id, row: %{generation: generation}}),
    do: row.lease_id == lease_id and row.generation == generation and row.state == "signed_in"

  defp ours?(nil, _leased), do: false

  defp lock_organisation(%Connection{organisation_id: id}),
    do: Repo.one(from o in Organisation, where: o.id == ^id, lock: "FOR SHARE")

  defp lock_secret(%Connection{secret_id: id, organisation_id: organisation_id}),
    do:
      Repo.one(
        from s in Secret,
          where: s.id == ^id and s.organisation_id == ^organisation_id,
          lock: "FOR UPDATE",
          select: s.id
      )

  defp lock_login(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.one(from l in __MODULE__, where: l.secret_value_id == ^id, lock: "FOR UPDATE")
    else
      :error -> nil
    end
  end

  # Each clause returns `{outcome, entry}`: what the caller gets, and what the entry of the
  # call returns (`record/2`).
  defp settle(write, row, {:ok, tokens}, now) do
    rotated? = is_binary(tokens.refresh_token)
    refresh_token = tokens.refresh_token || write.leased.tokens.refresh_token
    document = document(tokens.access_token, refresh_token)

    expires_at =
      case expiry(tokens.access_token) do
        {:ok, expires_at} -> expires_at
        {:error, _no_exp} -> nil
      end

    case Secrets.write_refreshed_key(
           write.ctx.provider,
           write.ctx.id,
           document,
           write.leased.snapshot
         ) do
      :ok ->
        update_row(row,
          access_expires_at: expires_at,
          refreshed_at: now,
          failures: 0,
          retry_at: nil,
          last_failure: nil,
          failing_since: nil,
          lease_id: nil,
          lease_until: nil,
          updated_at: now
        )

        {{:refreshed, tokens.access_token, expires_at}, entry(write, "refreshed", nil)}

      {:error, :invalid} ->
        failed(write, row, "bad_response", now)

      {:error, reason} when reason in [:changed, :not_found] ->
        dropped(write, row)

      {:error, reason} when rotated? ->
        log_not_stored(reason)
        {:store_failed, nil}

      {:error, reason} ->
        log_not_stored(reason)
        failed(write, row, "not_stored", now)
    end
  end

  defp settle(write, row, {:permanent, cause}, now) do
    update_row(row,
      state: "sign_in_needed",
      sign_in_cause: cause,
      failures: row.failures + 1,
      retry_at: nil,
      last_failure: now,
      failing_since: row.failing_since || now,
      lease_id: nil,
      lease_until: nil,
      updated_at: now
    )

    # The person has to act, whether or not a streak of failures that may pass was open: the
    # line of that streak shows the next call is scheduled.
    {:sign_in_needed, entry(write, "sign_in_needed", cause)}
  end

  defp settle(write, row, {:transient, cause}, now), do: failed(write, row, cause, now)

  # The reason a write returned an error, so that the cause of a `token_not_stored` can be
  # found: the reason's atom alone, never a token or a part of the response.
  defp log_not_stored(reason) do
    Logger.warning(
      "model key sign-in refresh: the new sign-in was not stored: " <>
        if(is_atom(reason), do: inspect(reason), else: "other")
    )
  end

  # A failure that may pass: the next call waits 30 seconds, doubling for each failure in a
  # row, at most 10 minutes. The first failure of a streak (`failing_since` nil) leaves the
  # entry, with the time of the next call as it is scheduled now; the failures after it
  # leave none, and the row carries their count. A failed store of a refresh token that the
  # provider kept leaves no entry and opens no streak: there is nothing for the person to do.
  defp failed(write, row, cause, now) do
    failures = row.failures + 1
    wait = min(@backoff_seconds * Integer.pow(2, min(failures - 1, 10)), @backoff_max_seconds)
    retry_at = DateTime.add(now, wait)
    silent? = cause == "not_stored"
    opens? = is_nil(row.failing_since) and not silent?

    update_row(
      row,
      [
        failures: failures,
        retry_at: retry_at,
        last_failure: now,
        lease_id: nil,
        lease_until: nil,
        updated_at: now
      ] ++ if(opens?, do: [failing_since: now], else: [])
    )

    {:failed, if(opens?, do: entry(write, "failed", cause, retry_at: retry_at))}
  end

  # A result that is not the key's any more leaves no entry: the key has what a person
  # signed in with since, or is gone, and the call changed nothing.
  defp dropped(_write, row) do
    if row, do: update_row(row, lease_id: nil, lease_until: nil)
    {:dropped, nil}
  end

  defp update_row(%__MODULE__{secret_value_id: id}, set) do
    Repo.update_all(from(l in __MODULE__, where: l.secret_value_id == ^id), set: set)
  end

  # What the entry of one call says, `{organisation, details}`: about the provider, with no
  # token and no part of the answer. The cause is one of the fixed words of
  # `Apiary.ModelKeys.LoginRefresh`, `causes/0`, `superseded` or `not_stored`; `retry_at` is
  # the time of the next call after a failure that may pass.
  defp entry(write, outcome, cause, extra \\ []) do
    %{ctx: ctx, reason: reason, organisation: organisation, value_id: value_id} = write

    {trigger, run_id} =
      case ctx.trigger do
        :schedule -> {"schedule", nil}
        {:run, run_id} -> {"run", run_id}
      end

    details =
      %{
        provider_id: ctx.provider.public_id,
        provider: ctx.provider.name,
        value_id: value_id,
        trigger: trigger,
        run_id: run_id,
        refresh_reason: reason,
        outcome: outcome,
        cause: cause,
        retry_at: extra[:retry_at] && DateTime.to_iso8601(extra[:retry_at])
      }
      |> Map.reject(fn {_name, value} -> is_nil(value) end)

    {organisation, details}
  end

  # The entry `model_key.refresh` of one call, by the instance, in the provider's
  # organisation's trail, written in a transaction after the outcome's, once that is stored:
  # an entry that cannot be written is logged by its kind and costs nothing else, as the
  # rotated token is stored already. Nil for a call with no organisation.
  defp record(_ctx, nil), do: :ok

  defp record(ctx, {organisation, details}) do
    case Audit.record(
           Repo,
           Scope.for_instance(organisation),
           :"model_key.refresh",
           ctx.provider,
           %{details: details}
         ) do
      {:ok, _entry} -> :ok
      {:error, _changeset} -> Logger.error("model key sign-in refresh: the entry was not written")
    end

    :ok
  rescue
    exception ->
      Logger.error(
        "model key sign-in refresh: the entry was not written: #{inspect(exception.__struct__)}"
      )

      :ok
  end
end
