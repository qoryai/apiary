defmodule Apiary.Runs do
  @moduledoc """
  The runs of a hive, as the console reads them.

  Events come in through `Apiary.Runs.Ingest`, are folded by `Apiary.Runs.Projector` and
  watched by `Apiary.Runs.Liveness`; this module is what pages call. Every function takes
  the caller's scope first and reads only the scope's hive; `closed?/2` is the one
  exception, for the receiver, which has an access key's hive and no user.

  Changes are announced on two topics of `Apiary.PubSub`:

    * `topic(hive_id)`, `"runs:<hive_id>"`: `{:run_changed, %Run{}}` whenever a run of the
      hive was projected, found lost or closed;
    * `topic(hive_id, run_id)`, `"run:<hive_id>:<run_id>"` (`run_id` is the row's id):
      `{:run_projected, %Run{}, first_sequence, last_sequence}` after a projection, with
      the lowest and highest sequence it folded, and `{:run_changed, %Run{}}` as above.
  """

  import Ecto.Query, warn: false

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations
  alias Apiary.Organisations.{Hive, Organisation}
  alias Apiary.Repo
  alias Apiary.Runs.Run

  @default_limit 50
  @max_limit 200

  ## Topics

  def topic(hive_id), do: "runs:#{hive_id}"
  def topic(hive_id, run_id), do: "run:#{hive_id}:#{run_id}"

  @doc "Subscribes the caller to the scope's hive."
  def subscribe(%Scope{hive: %Hive{id: hive_id}}) do
    Phoenix.PubSub.subscribe(Apiary.PubSub, topic(hive_id))
  end

  @doc "Subscribes the caller to one run of the scope's hive."
  def subscribe(%Scope{hive: %Hive{id: hive_id}}, %Run{id: id, hive_id: hive_id}) do
    Phoenix.PubSub.subscribe(Apiary.PubSub, topic(hive_id, id))
  end

  @doc false
  def broadcast_changed(%Run{} = run) do
    Phoenix.PubSub.broadcast(Apiary.PubSub, topic(run.hive_id), {:run_changed, run})
    Phoenix.PubSub.broadcast(Apiary.PubSub, topic(run.hive_id, run.id), {:run_changed, run})
  end

  @doc false
  def broadcast_projected(%Run{} = run, first_sequence, last_sequence) do
    Phoenix.PubSub.broadcast(Apiary.PubSub, topic(run.hive_id), {:run_changed, run})

    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      topic(run.hive_id, run.id),
      {:run_projected, run, first_sequence, last_sequence}
    )
  end

  ## Reads

  @doc "How many runs of the hive are alive now: pending or running."
  def count_alive(%Scope{} = scope) do
    Repo.aggregate(from(r in in_scope(scope), where: r.state in ^Run.alive_states()), :count)
  end

  @doc "One run of the scope's hive by its row id; raises when the hive has none such."
  def get_run!(%Scope{} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one!(from r in in_scope(scope), where: r.id == ^id)
      :error -> raise Ecto.NoResultsError, queryable: Run
    end
  end

  @doc "The hive's runs, newest first. `limit:` defaults to #{@default_limit}, at most #{@max_limit}."
  def list_runs(%Scope{} = scope, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@max_limit)

    Repo.all(
      from r in in_scope(scope), order_by: [desc: r.inserted_at, desc: r.id], limit: ^limit
    )
  end

  @doc "The last heartbeat each access key of the hive delivered, by the key's row id; keys that never did are absent."
  def last_heartbeats_by_key(%Scope{
        organisation: %Organisation{id: organisation_id},
        hive: %Hive{id: hive_id}
      }) do
    Repo.all(
      from k in AccessKey,
        where: k.organisation_id == ^organisation_id and k.hive_id == ^hive_id,
        where: not is_nil(k.last_heartbeat_at),
        select: {k.id, k.last_heartbeat_at}
    )
    |> Map.new()
  end

  @doc """
  Whether the hive has closed the run with this subject. For the receiver, which answers
  `410` to a closed run; a subject the hive has never seen is not closed.
  """
  def closed?(hive_id, run_id) do
    with {:ok, hive_id} <- Ecto.UUID.cast(hive_id),
         {:ok, run_id} <- Ecto.UUID.cast(run_id) do
      Repo.exists?(
        from r in Run,
          where: r.hive_id == ^hive_id and r.run_id == ^run_id and r.state == "closed"
      )
    else
      :error -> false
    end
  end

  ## Closing

  @doc """
  Closes the run: the hive takes no more events for it and the receiver answers `410`.
  Any member of the hive, read again from the database. A close is final: no event
  reopens the run, and closing a closed run changes nothing.

  `{:error, :unauthorized}` when the caller's membership is gone, `{:error, :not_found}`
  when the run is not one of the scope's hive.
  """
  def close_run(%Scope{user: user} = scope, %Run{id: id}) do
    with {:ok, _membership} <- Organisations.fetch_membership(scope) do
      now = DateTime.utc_now()

      query =
        from r in in_scope(scope),
          where: r.id == ^id and r.state != "closed",
          select: r

      case Repo.update_all(query,
             set: [state: "closed", closed_at: now, closed_by_id: user.id, updated_at: now]
           ) do
        {1, [run]} ->
          broadcast_changed(run)
          {:ok, run}

        {0, _} ->
          case Repo.one(from r in in_scope(scope), where: r.id == ^id) do
            %Run{} = run -> {:ok, run}
            nil -> {:error, :not_found}
          end
      end
    end
  end

  defp in_scope(%Scope{
         organisation: %Organisation{id: organisation_id},
         hive: %Hive{id: hive_id}
       }) do
    from r in Run, where: r.organisation_id == ^organisation_id and r.hive_id == ^hive_id
  end
end
