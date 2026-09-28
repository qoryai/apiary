defmodule Apiary.LogMetadata do
  @moduledoc """
  The organisation, workspace and person ids in the Logger metadata of the process.

  They are put where a request, a LiveView, a contract call or a job begins: the scope plugs
  and the LiveView mount hooks of `ApiaryWeb.UserAuth`, `ApiaryWeb.Contract.SignedRequest`
  and `Apiary.Job`. Every line logged below them carries them, as `organisation_id`,
  `workspace_id` and `user_id`, so a log search by any of them finds everything that
  happened for it. A task started from there takes them along: a LiveView's async work
  through `ApiaryWeb.Async` (`carry/1`), a projection by putting its run's. Where a line is
  written outside such a process, as a job's failure is by `Apiary.Job.Log`, it passes the
  ids itself (`metadata/3`).

  `user_id` is the person acting: the one signed in, on every page they open, or the one
  whose action enqueued a job. A person's own pages, their account settings and their
  organisations, carry `user_id` and no organisation or workspace: they are no
  organisation's. A contract call is an access key's, and carries no `user_id`.

  The ids only, never a name, a slug or an email address: the log holds no customer's or
  person's names. `user_id` is a pseudonymous id; once the person is deleted it names what
  is left of their row, and nothing more. A key without a value is left out of the metadata
  rather than logged empty, so work for an organisation alone has no `workspace_id`.
  """

  alias Apiary.Accounts.Scope

  @keys [:organisation_id, :workspace_id, :user_id]

  @typedoc "The ids as `get/0` reads them, each nil when unset."
  @type ids :: %{
          organisation_id: String.t() | nil,
          workspace_id: String.t() | nil,
          user_id: String.t() | nil
        }

  @doc "The metadata keys this module sets."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc """
  Puts the ids of a scope, its organisation, workspace and person, into the process's
  Logger metadata; or those of anything that carries `organisation_id` and `workspace_id`
  (an access key), with no person. A scope without an organisation leaves those two out;
  nil removes all three.
  """
  @spec put(Scope.t() | %{organisation_id: term(), workspace_id: term()} | nil) :: :ok
  def put(%Scope{organisation: organisation, workspace: workspace, user: user}),
    do: put_ids(id(organisation), id(workspace), id(user))

  def put(%{organisation_id: organisation_id, workspace_id: workspace_id}),
    do: put_ids(organisation_id, workspace_id, nil)

  def put(nil), do: clear()

  @doc """
  Puts the id of the scope's person as `user_id`, and nothing else: where a request or a
  LiveView knows who is signed in before it knows an organisation, if it ever does. A
  scope without a person, or nil, removes `user_id`.
  """
  @spec put_user(Scope.t() | nil) :: :ok
  def put_user(%Scope{user: user}), do: Logger.metadata(user_id: id(user))
  def put_user(nil), do: Logger.metadata(user_id: nil)

  @doc "Puts the three ids into the process's Logger metadata; a nil removes its key."
  @spec put_ids(String.t() | nil, String.t() | nil, String.t() | nil) :: :ok
  def put_ids(organisation_id, workspace_id, user_id \\ nil) do
    Logger.metadata(
      organisation_id: organisation_id,
      workspace_id: workspace_id,
      user_id: user_id
    )
  end

  @doc "The three ids as the process's Logger metadata holds them now, each nil when unset."
  @spec get() :: ids()
  def get do
    metadata = Logger.metadata()
    Map.new(@keys, &{&1, metadata[&1]})
  end

  @doc "Puts back ids `get/0` read."
  @spec restore(ids()) :: :ok
  def restore(%{organisation_id: organisation_id, workspace_id: workspace_id} = ids),
    do: put_ids(organisation_id, workspace_id, ids[:user_id])

  @doc "Removes the three ids from the process's Logger metadata."
  @spec clear() :: :ok
  def clear, do: put_ids(nil, nil, nil)

  @doc """
  Wraps `fun` so that it runs with the ids this process has now, in whichever process
  calls it: for a task started here, which starts with no Logger metadata of its own.
  """
  @spec carry((-> result)) :: (-> result) when result: term()
  def carry(fun) when is_function(fun, 0) do
    ids = get()

    fn ->
      restore(ids)
      fun.()
    end
  end

  @doc """
  The ids as Logger metadata for one line, `Logger.error(message, metadata)`: each only
  when it is a UUID, so a value that is not one never reaches the log.

      iex> Apiary.LogMetadata.metadata("0b0ae3a4-8f25-4e4c-a2a3-3c6f5c3b0a11", "a name")
      [organisation_id: "0b0ae3a4-8f25-4e4c-a2a3-3c6f5c3b0a11"]
  """
  @spec metadata(term(), term(), term()) :: keyword()
  def metadata(organisation_id, workspace_id, user_id \\ nil) do
    for {key, value} <- [
          organisation_id: organisation_id,
          workspace_id: workspace_id,
          user_id: user_id
        ],
        is_binary(value),
        {:ok, uuid} <- [Ecto.UUID.cast(value)],
        do: {key, uuid}
  end

  defp id(%{id: id}), do: id
  defp id(nil), do: nil
end
