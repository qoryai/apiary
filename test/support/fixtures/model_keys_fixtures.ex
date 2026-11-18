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

  @doc """
  Stores `keys` as the model keys of the run `run` (`Apiary.Runs.ModelKey`), as a claim
  stores them, and sets the run's `provider_connection_id` to the start key's provider:
  each a map or keyword list with `provider` (its row), `secret_value_id`, and any field
  of the row; `position` defaults to the key's place in `keys`, `name` to
  `<provider's public id>-<place>`, `start` to true on the first key, `chain` to
  `"organisation"`, `secret_id` to the provider's, `pause_for_s` to 60, and `api` to
  `api` of `opts`, else an Anthropic Messages API. Returns the rows in their order.
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
            start: position == 1,
            connection_id: provider.id,
            secret_id: provider.secret_id,
            chain: "organisation",
            api: api,
            pause_for_s: 60,
            chosen: false
          },
          Map.delete(key, :provider)
        )
        |> Map.put(:run_id, run_id)
      end)

    {_count, _rows} = Repo.insert_all(Apiary.Runs.ModelKey, rows)

    if start = Enum.find(rows, & &1.start) do
      Repo.update_all(from(r in Apiary.Runs.Run, where: r.id == ^run_id),
        set: [provider_connection_id: start.connection_id]
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
end
