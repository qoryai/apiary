defmodule Apiary.ModelKeys.Identity do
  @moduledoc """
  The identity line of a model provider's key: how every page, entry of the Activity page
  and sentence of a run's page shows a key. The key's name, the value id (`key-1`,
  `key-2`, …) that Qory Apiary sets when the key is added, is what the list Organisation
  settings › Model provider keys shows; it is changed on Edit key.

  The line is the provider's name (`provider.name`, as Edit key shows it), a
  middle dot and the text that distinguishes the keys of the provider:

    * a sign-in, `OpenAI subscription · dana@example.com`: the `email` claim of the
      sign-in's `id_token`; else, for a sign-in with no email, `OpenAI subscription · account
      …4f2a`, the last 4 characters of its account id (`Apiary.ModelKeys.Login`);
    * any other key, `Anthropic API · …9c2e`: the hint, the last 4 characters of the value
      (`Apiary.Secrets.Value.hint/1`);
    * the provider's name alone for a key with none of these: a key whose value has fewer
      than 12 characters, and a key saved before the hint existed.

  Two keys may have the same line. The line is text, to be shown as it is: the name and the
  email come from people and from the provider's token. An entry of the Activity page
  stores the line when the entry is written (`for_value_id/2`, `for_key/2`) and keeps it.
  """

  import Ecto.Query, warn: false

  alias Apiary.Connections.Connection
  alias Apiary.ModelKeys.Login
  alias Apiary.Repo
  alias Apiary.Secrets.Value

  @separator " · "
  @tail 4

  @doc """
  The identity line of a key of the provider named `name`, from the key's hint, `hint`,
  and its sign-in's row, `login`, nil for a key with none (`Apiary.ModelKeys.Login.by_key/1`).
  """
  @spec line(String.t(), String.t() | nil, Login.t() | nil) :: String.t()
  def line(name, hint, login)

  def line(name, _hint, %Login{email: email}) when is_binary(email),
    do: name <> @separator <> email

  def line(name, _hint, %Login{account_id: account_id}) when is_binary(account_id),
    do: name <> @separator <> "account …" <> tail(account_id)

  def line(name, hint, nil) when is_binary(hint) and hint != "",
    do: name <> @separator <> "…" <> hint

  def line(name, _hint, _login), do: name

  @doc """
  The identity line of `value`, a key of `provider` that has its `hint` loaded, as
  `line/3` makes it; `logins` is the provider's sign-ins by the key's row id
  (`Apiary.ModelKeys.Login.by_key/1`).
  """
  @spec of(Connection.t(), Value.t(), %{Ecto.UUID.t() => Login.t()}) :: String.t()
  def of(%Connection{name: name}, %Value{} = value, logins),
    do: line(name, value.hint, Map.get(logins, value.id))

  @doc """
  The identity lines of `values`, keys of `provider` that have their `hint` loaded, by the
  key's row id: one read of the provider's sign-ins for all of them.
  """
  @spec lines(Connection.t(), [Value.t()]) :: %{Ecto.UUID.t() => String.t()}
  def lines(%Connection{} = provider, values) do
    logins = Login.by_key(provider)
    Map.new(values, &{&1.id, of(provider, &1, logins)})
  end

  @doc """
  The identity line of the key of `provider` with the row id `row_id` (`secret_values.id`),
  read from the database, `provider.name` alone for a key that is not there.
  """
  @spec for_key(Connection.t(), Ecto.UUID.t()) :: String.t()
  def for_key(%Connection{} = provider, row_id), do: read(provider, dynamic([v], v.id == ^row_id))

  @doc """
  The identity line of the key of `provider` with the value id `value_id`, read from the
  database, `provider.name` alone for a key that is not there. A write reads it before it
  deletes the key, or after it sets the key's value, and stores it in its entry.
  """
  @spec for_value_id(Connection.t(), String.t()) :: String.t()
  def for_value_id(%Connection{} = provider, value_id),
    do: read(provider, dynamic([v], v.value_id == ^value_id))

  @doc """
  The row id and the identity line of the key of `provider` with the value id `value_id`,
  `{row_id, line}`, nil for a key that is not there: a page links a key's page by its row id.
  """
  @spec ref(Connection.t(), String.t()) :: {Ecto.UUID.t(), String.t()} | nil
  def ref(%Connection{} = provider, value_id),
    do: fetch(provider, dynamic([v], v.value_id == ^value_id))

  defp read(provider, match) do
    case fetch(provider, match) do
      {_row_id, line} -> line
      nil -> provider.name
    end
  end

  defp fetch(
         %Connection{secret_id: secret_id, organisation_id: organisation_id} = provider,
         match
       )
       when is_binary(secret_id) do
    key =
      Repo.one(
        from v in Value,
          left_join: l in Login,
          on: l.secret_value_id == v.id,
          where: v.secret_id == ^secret_id and v.organisation_id == ^organisation_id,
          where: ^match,
          select: {v.id, v.hint, l}
      )

    case key do
      {row_id, hint, login} -> {row_id, line(provider.name, hint, login)}
      nil -> nil
    end
  end

  defp fetch(%Connection{}, _match), do: nil

  # The last 4 characters of an account id, all of a shorter one.
  defp tail(account_id), do: String.slice(account_id, -@tail, @tail)
end
