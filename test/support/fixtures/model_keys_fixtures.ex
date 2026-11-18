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

  @doc "`seconds` from now, in whole seconds."
  def in_seconds(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.truncate(:second)

  @doc "The JSON pointer of the account id in the access token of a login, as the catalogue has it."
  def account_claim, do: "/https:~1~1api.openai.com~1auth/chatgpt_account_id"

  @doc """
  The tokens of a login as a device sign-in returns them: a map with `access_token`, a JWT
  that expires `expires_in` seconds from now (default 10 days) or at `exp` and has the
  account id in its claim, `refresh_token`, `id_token` and `account_id`. `tag` makes the
  values differ between logins.
  """
  def login_tokens(opts \\ []) do
    tag = Keyword.get(opts, :tag, "a")
    account_id = "acct-fixture-#{tag}"

    exp =
      Keyword.get(opts, :exp, System.os_time(:second) + Keyword.get(opts, :expires_in, 864_000))

    %{
      access_token:
        jwt(%{
          "exp" => exp,
          "client_id" => "app-fixture",
          "jti" => "access-#{tag}",
          "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
        }),
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

    {:ok, login} =
      Apiary.ModelKeys.Login.from_tokens(
        %{
          "access_token" => tokens.access_token,
          "refresh_token" => tokens.refresh_token,
          "id_token" => tokens.id_token
        },
        account_claim()
      )

    login
  end

  @doc "A JWT with `claims` and a signature that checks nothing."
  def jwt(claims) do
    encode = &Base.url_encode64(Jason.encode!(&1), padding: false)

    "#{encode.(%{"alg" => "RS256", "typ" => "JWT"})}.#{encode.(claims)}.#{Base.url_encode64("signature-fixture", padding: false)}"
  end
end
