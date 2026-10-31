defmodule Apiary.Harnesses.PublicGit.Cache do
  # The files `Apiary.Harnesses.PublicGit` read, by `{git, commit, path}`, across walks:
  # a commit's files never change, so an entry has no expiry. A file a commit does not
  # have is kept too, as nil. Only a full commit id is a key: a branch or tag name is
  # resolved again by every read, and its commit is then the key.
  #
  # The table is bounded by bytes, `budget` (16 MiB by default): each entry counts its
  # content, its key, and 64 bytes. An entry that would pass the budget first removes the
  # oldest entries, in the order they were put, until it fits; an entry larger than the
  # budget is not kept. Reads go to the table, without the process; writes go through the
  # process, one at a time.
  @moduledoc false
  use GenServer

  @budget 16 * 1024 * 1024
  @overhead 64

  @typedoc "A file's key: the repository's address, a full commit id, and the path."
  @type key :: {String.t(), String.t(), String.t()}

  @doc false
  # start_link/1 starts the cache. `opts`: `name` (this module), `budget` in bytes.
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc false
  # get/2 is the file at `key`: `{:ok, content}`, nil for a file the commit does not
  # have, or `:miss`.
  @spec get(key, atom) :: {:ok, binary | nil} | :miss
  def get(key, name \\ __MODULE__) do
    case :ets.lookup(table(name), {:key, key}) do
      [{_key, content, _bytes, _order}] -> {:ok, content}
      [] -> :miss
    end
  rescue
    # No table: the cache is not running.
    ArgumentError -> :miss
  end

  @doc false
  # put/3 keeps `content`, a binary or nil, at `key`, removing the oldest entries while
  # the budget would be passed.
  @spec put(key, binary | nil, atom) :: :ok
  def put({git, commit, path} = key, content, name \\ __MODULE__)
      when is_binary(git) and is_binary(commit) and is_binary(path) do
    GenServer.call(name, {:put, key, content})
  catch
    :exit, _not_running -> :ok
  end

  @doc false
  # bytes/1 is the bytes the cache counts now.
  @spec bytes(atom) :: non_neg_integer
  def bytes(name \\ __MODULE__), do: GenServer.call(name, :bytes)

  defp table(name), do: :"#{name}.Table"

  @impl GenServer
  def init(opts) do
    table =
      :ets.new(table(Keyword.fetch!(opts, :name)), [
        :ordered_set,
        :named_table,
        :protected,
        read_concurrency: true
      ])

    {:ok, %{table: table, budget: Keyword.get(opts, :budget, @budget), bytes: 0, order: 0}}
  end

  @impl GenServer
  def handle_call({:put, {git, commit, path} = key, content}, _from, state) do
    size = byte_size(content || "") + byte_size(git) + byte_size(commit) + byte_size(path)
    bytes = size + @overhead

    state =
      cond do
        :ets.member(state.table, {:key, key}) -> state
        bytes > state.budget -> state
        true -> state |> evict(state.budget - bytes) |> insert(key, content, bytes)
      end

    {:reply, :ok, state}
  end

  def handle_call(:bytes, _from, state), do: {:reply, state.bytes, state}

  defp insert(state, key, content, bytes) do
    order = state.order + 1
    :ets.insert(state.table, [{{:key, key}, content, bytes, order}, {{:order, order}, key}])
    %{state | bytes: state.bytes + bytes, order: order}
  end

  # The oldest entries removed until at most `room` bytes are counted.
  defp evict(%{bytes: bytes} = state, room) when bytes <= room, do: state

  defp evict(state, room) do
    {:order, order} = oldest = :ets.next(state.table, {:order, 0})
    [{_order, key}] = :ets.lookup(state.table, oldest)
    [{_key, _content, bytes, ^order}] = :ets.lookup(state.table, {:key, key})
    :ets.delete(state.table, oldest)
    :ets.delete(state.table, {:key, key})
    evict(%{state | bytes: state.bytes - bytes}, room)
  end
end
