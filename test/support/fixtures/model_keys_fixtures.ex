defmodule Apiary.ModelKeysFixtures do
  @moduledoc "Test helpers for the states of model keys (`Apiary.ModelKeys`)."

  import Ecto.Query, only: [from: 2]

  alias Apiary.Connections.Connection
  alias Apiary.Repo
  alias Apiary.Secrets.Value

  @doc "The key `value_id` of the model provider `provider`, its row of `secret_values`."
  def key_value!(%{secret_id: secret_id}, value_id),
    do: Repo.one!(from v in Value, where: v.secret_id == ^secret_id and v.value_id == ^value_id)

  @doc """
  The plaintext of the key `secret_value_id` of the model provider `provider`, as the gate
  reads a key that is no sign-in (`Apiary.Secrets.reveal_key_and_set_at/2`), without the
  time the value was set: `{:ok, plaintext}` or `{:error, reason}`.
  """
  def revealed_key(provider, secret_value_id) do
    with {:ok, plaintext, _set_at} <-
           Apiary.Secrets.reveal_key_and_set_at(provider, secret_value_id),
         do: {:ok, plaintext}
  end

  @doc """
  Writes the state of the key `value_id` of `provider` in its 5-hour window, as a
  gateway's report of a run with the key's value writes it (`Apiary.ModelKeys.record/3`).
  With `until`, the key is in
  cooldown until then, and its reset is then; else it is allowed, with a reset at
  `resets_at` (none by default).
  """
  def key_state!(%{} = provider, value_id, attrs \\ []) do
    value = key_value!(provider, value_id)
    until = attrs[:until]

    Apiary.ModelKeys.record(
      [
        %{
          name: "k",
          secret_value_id: value.id,
          organisation_id: value.organisation_id,
          copy_set_at: value.value_set_at,
          copy_kept: true
        }
      ],
      [
        %{
          credential: "k",
          window: "five_hour",
          status: if(until, do: "rejected", else: "allowed"),
          resets_at: attrs[:resets_at] || until,
          utilization: nil,
          cooldown_until: until,
          source: "provider",
          observed_at: DateTime.utc_now()
        }
      ],
      DateTime.utc_now()
    )
  end

  @doc """
  Saves `settings` as the settings of the model key `value` under `scope`, as Edit key
  saves them (`Apiary.Connections.update_provider_key/4`): `{:ok, setting}`, the key's
  settings as stored, nil for none, or `{:error, refusal}`.
  """
  def put_key_setting(scope, %Value{} = value, settings) do
    provider = Repo.one!(from c in Connection, where: c.secret_id == ^value.secret_id)
    attrs = %{"value_id" => value.value_id, "settings" => settings}

    with {:ok, _provider} <-
           Apiary.Connections.update_provider_key(scope, provider, value.value_id, attrs),
         do: {:ok, Apiary.ModelKeys.setting(value.id)}
  end

  @doc "Puts every key of `provider` in cooldown until `until`."
  def cooling!(%Connection{} = provider, until) do
    for %Value{value_id: value_id} <-
          Repo.all(from v in Value, where: v.secret_id == ^provider.secret_id),
        do: key_state!(provider, value_id, until: until)

    provider
  end

  @doc """
  Stores `keys` as the model keys of the run `run` (`Apiary.Runs.ModelKey`), as a claim
  stores them, and sets the run's `provider_connection_id` to the default model provider
  credential's provider: each a map or keyword list with `provider` (its row),
  `secret_value_id`, and any field of the row; `position` defaults to the key's place in
  `keys`, `name` to `<provider's public id>-<place>`, `default_credential` to true on the
  first key, `chain` to `"organisation"`, `secret_id` to the provider's, `pause_for_s` to
  60, and `api` to `api` of `opts`, else an Anthropic Messages API. Returns the rows in
  their order.
  """
  def run_keys!(%{id: run_id}, keys, opts \\ []) when is_binary(run_id) do
    api =
      opts[:api] ||
        %{
          "format" => "anthropic-messages",
          "endpoint" => "https://api.anthropic.com",
          "auth" => %{"scheme" => "header", "header" => "x-api-key"}
        }

    rows =
      keys
      |> Enum.with_index(1)
      |> Enum.map(fn {key, position} ->
        key = Map.new(key)
        provider = Map.fetch!(key, :provider)

        Map.merge(
          %{
            position: position,
            name: "#{provider.public_id}-#{position}",
            default_credential: position == 1,
            connection_id: provider.id,
            secret_id: provider.secret_id,
            chain: "organisation",
            api: api,
            pause_for_s: 60
          },
          Map.delete(key, :provider)
        )
        |> Map.put(:run_id, run_id)
      end)

    {_count, _rows} = Repo.insert_all(Apiary.Runs.ModelKey, rows)

    if default = Enum.find(rows, & &1.default_credential) do
      Repo.update_all(from(r in Apiary.Runs.Run, where: r.id == ^run_id),
        set: [provider_connection_id: default.connection_id]
      )
    end

    stored_keys(run_id)
  end

  @doc "The model keys stored for the run `run`, or of the run id, in their order."
  def stored_keys(%{id: run_id}), do: stored_keys(run_id)

  def stored_keys(run_id) when is_binary(run_id),
    do:
      Repo.all(
        from k in Apiary.Runs.ModelKey, where: k.run_id == ^run_id, order_by: [asc: k.position]
      )

  @doc "`seconds` from now, in whole seconds."
  def in_seconds(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.truncate(:second)

  @doc "The JSON pointer of the account id in the access token of a login, as the catalogue has it."
  def account_claim, do: "/https:~1~1api.openai.com~1auth/chatgpt_account_id"

  @doc """
  The tokens of a login as a device sign-in returns them: a map with `access_token`, a JWT
  that expires `expires_in` seconds from now (default 10 days) or at `exp` and has the
  account id in its claim (`account_claim/0`), unless `account: false`, a token with no
  account id, `refresh_token`, `id_token` and `account_id`. `tag` makes the values differ
  between logins.
  """
  def login_tokens(opts \\ []) do
    tag = Keyword.get(opts, :tag, "a")
    account_id = "acct-fixture-#{tag}"

    exp =
      Keyword.get(opts, :exp, System.os_time(:second) + Keyword.get(opts, :expires_in, 864_000))

    account =
      if Keyword.get(opts, :account, true),
        do: %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}},
        else: %{}

    %{
      access_token:
        jwt(
          Map.merge(
            %{"exp" => exp, "client_id" => "app-fixture", "jti" => "access-#{tag}"},
            account
          )
        ),
      refresh_token: "rt-fixture-refresh-token-#{tag}-0123456789",
      id_token:
        jwt(%{"exp" => exp - 860_000, "email" => "dana@example.com", "jti" => "id-#{tag}"}),
      account_id: account_id
    }
  end

  @doc """
  The sign-in that a device sign-in makes (`Apiary.ModelKeys.Login.from_tokens/3`), with the
  tokens of `login_tokens/1`: what a form passes to `Apiary.Connections` as a key's value.
  """
  def device_login(opts \\ []) do
    tokens = Keyword.get_lazy(opts, :tokens, fn -> login_tokens(opts) end)

    login =
      case Apiary.ModelKeys.Login.from_tokens(
             %{
               "access_token" => tokens.access_token,
               "refresh_token" => tokens.refresh_token,
               "id_token" => tokens.id_token
             },
             account_claim()
           ) do
        {:ok, login} ->
          login

        # `from_tokens/3` refuses an access token with no account id, as a sign-in does. A
        # test of a stored login whose token has none (`login_tokens(account: false)`), as
        # a refresh can leave it, needs the row that a sign-in with an id would have made.
        {:error, :no_account} ->
          %Apiary.ModelKeys.Login.Parsed{
            document:
              Jason.encode!(%{
                "version" => 1,
                "access_token" => tokens.access_token,
                "refresh_token" => tokens.refresh_token
              }),
            account_id: tokens.account_id,
            access_expires_at: nil
          }
      end

    # `from_tokens/3` keeps an `exp` only from 1 second to 366 days ahead, as a device
    # sign-in's tokens have it. A test of a refresh needs a token that has expired, or one
    # that expires in a year, as a stored row has them after a refresh, so the fixture
    # sets the expiry from the token's `exp` as it is.
    with [_header, payload, _signature] <- String.split(tokens.access_token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"exp" => exp}} when is_integer(exp) <- Jason.decode(json) do
      %{login | access_expires_at: %{DateTime.from_unix!(exp) | microsecond: {0, 6}}}
    else
      _no_exp -> login
    end
  end

  @doc """
  Replaces the access token in the stored document of the sign-in `secret_value_id` of
  `provider` with `access_token`, as a refresh writes it, and keeps the refresh token and
  the sign-in's row. For a test of a stored token that a device sign-in refuses to make,
  such as one with no account id (`login_tokens(account: false)`).
  """
  def store_access_token!(provider, secret_value_id, access_token) do
    plain = Repo.get!(Connection, provider.id)
    {:ok, plaintext, snapshot} = Apiary.Secrets.reveal_login_snapshot(plain, secret_value_id)
    %{"refresh_token" => refresh_token} = Jason.decode!(plaintext)

    document =
      Jason.encode!(%{
        "version" => 1,
        "access_token" => access_token,
        "refresh_token" => refresh_token
      })

    :ok = Apiary.Secrets.write_refreshed_key(plain, secret_value_id, document, snapshot)
  end

  @doc "A JWT with `claims` and a signature that checks nothing."
  def jwt(claims) do
    encode = &Base.url_encode64(Jason.encode!(&1), padding: false)

    "#{encode.(%{"alg" => "RS256", "typ" => "JWT"})}.#{encode.(claims)}.#{Base.url_encode64("signature-fixture", padding: false)}"
  end

  @doc """
  The key `value` of a new run of `scope`, as a report of the run's keys reads it
  (`Apiary.ModelKeys.run_keys/1`, for `Apiary.ModelKeys.reject/4`): the run is handed over
  to a gateway, and a secrets request has kept the copy of the value, `copy_set_at` its
  `value_set_at`, with `copy_login_at` for a sign-in. `name` is the key's credential name.
  """
  def run_key!(scope, %Value{} = value, name \\ "model-1", copy_login_at \\ nil) do
    provider = Repo.get_by!(Connection, secret_id: value.secret_id)
    pool = Apiary.NodesFixtures.pool_fixture(scope)
    %{access_key: access_key} = Apiary.AccessKeysFixtures.enrolled_key_fixture(scope, pool)

    %{run: run} =
      Apiary.DispatchedRunsFixtures.handed_over_fixture(scope, access_key, %{
        provider_connection_id: provider.id,
        run_settings: %{}
      })

    run_keys!(run, [%{provider: provider, secret_value_id: value.id, name: name}])

    :ok =
      Apiary.ModelKeys.keep_copies(run.id, [{value.id, value.value_set_at, copy_login_at}])

    %{
      name: name,
      run_id: run.id,
      secret_value_id: value.id,
      organisation_id: value.organisation_id,
      copy_set_at: value.value_set_at,
      copy_kept: true,
      copy_login_at: copy_login_at,
      copy_login_sealed_at: nil
    }
  end
end
