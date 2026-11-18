defmodule Apiary.ModelKeys.Login do
  @moduledoc """
  The sign-in of a model key whose provider's API has `oauth_refresh` in its catalogue
  entry, such as an OpenAI subscription: the contents of the `auth.json` that `codex login`
  writes, pasted as the key's value. The key is still one value of the provider's secret
  (`Apiary.ModelKeys`). Its stored value is the document `parse/1` makes from the paste,
  `{"version": 1, "access_token", "refresh_token", "id_token"}`, encrypted like any other
  key value, and nothing else of the paste is kept. The row of this module has what the
  server needs to know about the sign-in without decrypting it: the account, when the
  access token expires, and whether the provider still accepts the refresh token.

  `parse/1` reads the paste and makes no network call. It reads the access token's `exp`
  from the JWT's payload without checking the signature: the server only uses the time to
  decide when to refresh. A paste that is not an `auth.json` with a string for each of
  `tokens.access_token`, `tokens.refresh_token`, `tokens.id_token` and `tokens.account_id`,
  and an access token with an `exp`, is refused with a reason (`refusal/1`) that never
  contains any of the paste.

  `put/3` writes the row of a key's new login: `generation` 1, plus 1 for each login pasted
  over it, so a refresh that started before it can be dropped. The caller is
  `Apiary.Connections`, in the transaction that stores the value.

  Only this module reads the tokens (`tokens/2`): `Apiary.Secrets.reveal_key_and_set_at/2`
  refuses the key of such a provider with `{:error, :login}`, so a login is never sealed
  into a run as it is stored.
  """

  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, warn: false

  alias Apiary.Connections.Connection
  alias Apiary.Kinds.{Provider, Providers}
  alias Apiary.Repo
  alias Apiary.Secrets
  alias Apiary.Secrets.Value

  @typedoc "The row of a key's sign-in."
  @type t :: %__MODULE__{}

  defmodule Parsed do
    @moduledoc false
    # What `Apiary.ModelKeys.Login.parse/1` reads from a paste. `document` has the
    # tokens, so `inspect/2` shows the account and the expiry alone.
    @derive {Inspect, only: [:account_id, :access_expires_at]}
    @enforce_keys [:document, :account_id, :access_expires_at]
    defstruct [:document, :account_id, :access_expires_at]
  end

  @typedoc "What `parse/1` reads from a paste."
  @type parsed :: %Parsed{
          document: binary,
          account_id: String.t(),
          access_expires_at: DateTime.t()
        }

  @states ~w(signed_in sign_in_needed)
  # The provider's permanent refusals of a refresh (plan 521): the refresh token expired,
  # was used already, or was invalidated; a 400 `invalid_grant`; any 401.
  @causes ~w(refresh_token_expired refresh_token_reused refresh_token_invalidated
             invalid_grant unauthorized)
  @paste_max 32_768
  @account_id_max 255

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
    field :generation, :integer, default: 1
    field :lease_id, :binary_id
    field :lease_until, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @doc "The states of a sign-in: `signed_in` and `sign_in_needed`."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The causes a provider's permanent refusal of a refresh has."
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
  Reads a pasted login: `{:ok, parsed}` with the document to store as the key's value, the
  account id and when the access token expires, or `{:error, reason}`:
  `:no_refresh_token` for an `auth.json` whose `tokens` have no refresh token, `:invalid`
  for any other paste that is not a login. It makes no network call, never raises, and its
  answers contain nothing of `text`.
  """
  @spec parse(term) :: {:ok, parsed} | {:error, :invalid | :no_refresh_token}
  def parse(text) when is_binary(text) and byte_size(text) <= @paste_max do
    with {:ok, %{"tokens" => %{} = tokens}} <- decode(text),
         {:ok, refresh_token} <- string(tokens, "refresh_token", :no_refresh_token),
         {:ok, access_token} <- string(tokens, "access_token", :invalid),
         {:ok, id_token} <- string(tokens, "id_token", :invalid),
         {:ok, account_id} <- string(tokens, "account_id", :invalid),
         true <- String.length(account_id) <= @account_id_max or {:error, :invalid},
         {:ok, expires_at} <- expiry(access_token),
         document = document(access_token, refresh_token, id_token),
         true <- byte_size(document) <= Value.value_max() or {:error, :invalid} do
      {:ok, %Parsed{document: document, account_id: account_id, access_expires_at: expires_at}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid}
    end
  end

  def parse(_text), do: {:error, :invalid}

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = login} -> {:ok, login}
      _other -> :error
    end
  end

  defp string(map, name, reason) do
    case map do
      %{^name => value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, reason}
    end
  end

  # The `exp` of a JWT's payload, in whole seconds since 1970, as a time. The signature is
  # not checked: the time only decides when to refresh.
  defp expiry(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"exp" => exp}} when is_integer(exp) <- Jason.decode(json),
         {:ok, at} <- DateTime.from_unix(exp) do
      {:ok, %{at | microsecond: {0, 6}}}
    else
      _other -> {:error, :invalid}
    end
  end

  defp document(access_token, refresh_token, id_token) do
    Jason.encode!(%{
      "version" => 1,
      "access_token" => access_token,
      "refresh_token" => refresh_token,
      "id_token" => id_token
    })
  end

  @doc """
  The refusal of a paste that `parse/1` refused, as an `{message, options}` for a form's
  error: one sentence for any paste that is not a login, which for a paste without a
  refresh token adds why.
  """
  @spec refusal(:invalid | :no_refresh_token) :: {String.t(), keyword}
  def refusal(:invalid),
    do: {dgettext_noop("errors", "Paste the whole auth.json that codex login wrote."), []}

  def refusal(:no_refresh_token),
    do:
      {dgettext_noop(
         "errors",
         "Paste the whole auth.json that codex login wrote. This text has no refresh token."
       ), []}

  @doc """
  The refusal of the paste `text` for a form: nil for a blank text, which the checks of
  the value refuse, and for a login that `parse/1` reads.
  """
  @spec problem(term) :: {String.t(), keyword} | nil
  def problem(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        nil

      trimmed ->
        case parse(trimmed) do
          {:ok, _parsed} -> nil
          {:error, reason} -> refusal(reason)
        end
    end
  end

  def problem(_text), do: nil

  @doc """
  Writes the row of the key `value`'s new login `parsed`, in the caller's transaction: the
  state `signed_in`, no failure, no lease, `refreshed_at` nil and `signed_in_at` `now`;
  `generation` is 1 for a new key, and the key's plus 1 for a login pasted over another.
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
  nothing else: `{:ok, %{access_token:, refresh_token:, id_token:}}`, or `{:error, reason}`
  as `Apiary.Secrets.reveal_login/2` returns, with `:invalid` for a stored value that is
  not the document `parse/1` makes. The tokens go to the provider's token endpoint and
  nowhere else: not into a log, an assign, an error or an audit entry.
  """
  @spec tokens(Connection.t(), Ecto.UUID.t()) ::
          {:ok, %{access_token: String.t(), refresh_token: String.t(), id_token: String.t()}}
          | {:error, :not_found | :unavailable | :invalid}
  def tokens(%Connection{} = provider, secret_value_id) do
    with {:ok, plaintext} <- Secrets.reveal_login(provider, secret_value_id) do
      case Jason.decode(plaintext) do
        {:ok,
         %{
           "version" => 1,
           "access_token" => access_token,
           "refresh_token" => refresh_token,
           "id_token" => id_token
         }}
        when is_binary(access_token) and is_binary(refresh_token) and is_binary(id_token) ->
          {:ok, %{access_token: access_token, refresh_token: refresh_token, id_token: id_token}}

        _other ->
          {:error, :invalid}
      end
    end
  end
end
