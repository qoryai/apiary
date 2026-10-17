defmodule Apiary.Environments do
  @moduledoc false

  # The environment records of the collections (`Apiary.Environments.Record`), one per
  # node pool and collection: what the last prebuild of a collection's target built for a
  # pool, and what was asked of it.
  #
  # The reads here serve the paths that queue, record and use a build: they ask nothing
  # of `Apiary.Access`, and whoever answers a person with them asks it first.

  import Ecto.Query, only: [from: 2]

  alias Apiary.Environments.Record
  alias Apiary.Repo

  # fetch/2 is the record of the pool `pool_id` and the collection `collection_id`, or nil.
  @doc false
  @spec fetch(Ecto.UUID.t(), Ecto.UUID.t()) :: Record.t() | nil
  def fetch(pool_id, collection_id) when is_binary(pool_id) and is_binary(collection_id),
    do: Repo.get_by(Record, pool_id: pool_id, source_collection_id: collection_id)

  # for_collection/1 is every record of the collection `collection_id`, of any pool and
  # workspace, the oldest first.
  @doc false
  @spec for_collection(Ecto.UUID.t()) :: [Record.t()]
  def for_collection(collection_id) when is_binary(collection_id) do
    Repo.all(
      from r in Record,
        where: r.source_collection_id == ^collection_id,
        order_by: [asc: r.inserted_at, asc: r.id]
    )
  end
end
