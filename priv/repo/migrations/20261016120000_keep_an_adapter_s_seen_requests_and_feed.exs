defmodule Apiary.Repo.Migrations.KeepAnAdapterSSeenRequestsAndFeed do
  use Ecto.Migration

  # What the signed requests of an adapter (a node of kind `adapter`, the instance's, with
  # no organisation) leave behind, as the integration contract has it:
  #
  # - `adapter_seen_requests`: the signature of every request of an adapter's access key
  #   that was accepted, its 64 decoded bytes, kept until `expires_at`, so the same request
  #   sent again is refused on any node of a cluster: the primary key is the key and the
  #   signature, and a second insert of the pair finds the first. A periodic job deletes
  #   the rows past `expires_at` (`Apiary.Adapters.SeenRequests`).
  # - `adapter_feed_counters`: one row per adapter, made with its first feed entry,
  #   holding the last sequence number given. A number is taken by an upsert that adds
  #   one, inside the transaction that writes the entry, so the row stays locked until it
  #   commits: entries become visible in the order of their numbers, and a reader that
  #   follows the numbers never passes one that commits later.
  # - `adapter_feed`: the adapter's change feed, one row per entry, numbered from 1 per
  #   adapter, never twice. `kind` is one of the contract's kinds, `work_item`,
  #   `collection` or `sync`; `data` is a JSON object of the entry's other members, 4 KiB
  #   at most (`Apiary.Adapters.Feed`).
  #
  # None of them has an organisation: an adapter and its keys are the instance's. An
  # adapter's row is never deleted (its deletion marks it), and an access key's neither,
  # so the keys to them hold no row back.
  def change do
    create table(:adapter_seen_requests, primary_key: false) do
      add :access_key_id,
          references(:access_keys, type: :binary_id, on_delete: :delete_all),
          null: false,
          primary_key: true

      add :signature, :binary, null: false, primary_key: true
      add :expires_at, :utc_datetime_usec, null: false
    end

    create index(:adapter_seen_requests, [:expires_at])

    create constraint(:adapter_seen_requests, :adapter_seen_requests_signature_check,
             check: "octet_length(signature) = 64"
           )

    create table(:adapter_feed_counters, primary_key: false) do
      add :adapter_id,
          references(:nodes, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :last_seq, :bigint, null: false
    end

    create constraint(:adapter_feed_counters, :adapter_feed_counters_last_seq_check,
             check: "last_seq >= 1"
           )

    create table(:adapter_feed, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :adapter_id, references(:nodes, type: :binary_id, on_delete: :delete_all), null: false
      add :seq, :bigint, null: false
      add :kind, :text, null: false
      add :data, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:adapter_feed, [:adapter_id, :seq])

    create constraint(:adapter_feed, :adapter_feed_seq_check, check: "seq >= 1")

    create constraint(:adapter_feed, :adapter_feed_kind_check,
             check: "kind IN ('work_item', 'collection', 'sync')"
           )

    create constraint(:adapter_feed, :adapter_feed_data_check,
             check: "jsonb_typeof(data) = 'object' AND octet_length(data::text) <= 4096"
           )
  end
end
