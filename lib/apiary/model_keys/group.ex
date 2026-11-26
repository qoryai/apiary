defmodule Apiary.ModelKeys.Group do
  @moduledoc """
  The key group of a run: every model provider of an organisation with the same
  `provider_kind`, `chain` and `settings` (its address, as stored: settings are canonical
  JSON) as the provider of the run's model choice, of those that serve the run's
  workspace (`applies_to` `all`, or the workspace among its `connection_workspaces`). A
  run takes its keys from every provider of the group, as one ordered list
  (`Apiary.ModelKeys.Order`), and waits only while every key of the group is in cooldown.
  The provider a choice or a fallback points at is the group's head: it comes first, its
  default key is the group's default key, and its public id is the group's `group` in the
  run configuration.

  `same?/2` and `members/3` read rows already loaded; `member_ids/4` reads the database,
  without a lock.
  """

  import Ecto.Query, only: [from: 2, dynamic: 1, dynamic: 2]

  alias Apiary.Connections
  alias Apiary.Connections.{Connection, ConnectionWorkspace}
  alias Apiary.Repo
  alias Apiary.Secrets.Value

  require Logger

  # The fields that the providers of one key group share, whatever their workspaces.
  @shared [:organisation_id, :provider_kind, :chain, :settings]

  @doc """
  Whether the providers `a` and `b` are of one key group, whatever their workspaces: one
  organisation, one `provider_kind`, one `chain` and one `settings`.
  """
  @spec same?(Connection.t(), Connection.t()) :: boolean
  def same?(%Connection{provider_kind: kind} = a, %Connection{} = b) when is_binary(kind),
    do: identity(a) == identity(b)

  def same?(%Connection{}, %Connection{}), do: false

  @doc """
  What the providers of one key group have in common, whatever their workspaces: the
  organisation, `provider_kind`, `chain` and `settings` of `provider`.
  """
  @spec identity(Connection.t()) :: {Ecto.UUID.t(), String.t() | nil, String.t(), String.t()}
  def identity(%Connection{} = provider),
    do: @shared |> Enum.map(&Map.fetch!(provider, &1)) |> List.to_tuple()

  @doc """
  The providers of `query`, a query of `Apiary.Connections.Connection`, of the key group of
  `provider`, whatever their workspaces: those with its `identity/1`. `provider` can be a
  row not yet inserted, such as the provider a new key would make. Its `provider_kind` is
  not nil.
  """
  @spec of(Ecto.Queryable.t(), Connection.t()) :: Ecto.Query.t()
  def of(query \\ Connection, %Connection{provider_kind: kind} = provider)
      when is_binary(kind),
      do: from(c in query, where: ^Enum.zip(@shared, Tuple.to_list(identity(provider))))

  @doc """
  Whether `provider`, loaded with its workspaces, serves the workspace `workspace_id`.
  """
  @spec serves?(Connection.t(), Ecto.UUID.t()) :: boolean
  def serves?(%Connection{applies_to: "all"}, _workspace_id), do: true

  def serves?(%Connection{workspaces: workspaces}, workspace_id) when is_list(workspaces),
    do: Enum.any?(workspaces, &(&1.workspace_id == workspace_id))

  def serves?(%Connection{}, _workspace_id), do: false

  @doc """
  The key group of `head` for the workspace `workspace_id`, of the providers `providers`,
  rows loaded with their workspaces: `head` first, then each other provider of `head`'s
  group that serves the workspace and passes its integrity code
  (`Apiary.Connections.intact?/1`), by the time it was added, then by its row id. A
  provider that fails its integrity code is left out, with a line in the log, as its
  secret id is read only from a row whose code verifies.
  """
  @spec members(Connection.t(), [Connection.t()], Ecto.UUID.t()) :: [Connection.t()]
  def members(%Connection{} = head, providers, workspace_id) when is_list(providers) do
    others =
      providers
      |> Enum.filter(&(&1.id != head.id and same?(head, &1) and serves?(&1, workspace_id)))
      |> Enum.filter(&intact?/1)
      |> Enum.sort_by(&added/1)

    [head | others]
  end

  defp intact?(%Connection{} = provider) do
    if Connections.intact?(provider) do
      true
    else
      Logger.error(
        "a claim leaves the model provider #{provider.public_id} out of its key group: " <>
          "it fails its integrity code"
      )

      false
    end
  end

  @doc """
  The first provider of each key group among `providers`, rows that serve one workspace,
  by the time it was added, then by its row id, as `members/3` orders a group; in the
  order of each group's first row in `providers`. A provider with no `provider_kind` is a
  group alone. `{firsts, first_of}`: `first_of` is the row id of the first provider of
  each provider's group, by the provider's row id. Integrity codes are not checked.
  """
  @spec firsts([Connection.t()]) :: {[Connection.t()], %{Ecto.UUID.t() => Ecto.UUID.t()}}
  def firsts(providers) when is_list(providers) do
    groups =
      providers
      |> Enum.group_by(&key/1)
      |> Map.new(fn {key, rows} -> {key, Enum.min_by(rows, &added/1)} end)

    firsts = providers |> Enum.map(&Map.fetch!(groups, key(&1))) |> Enum.uniq_by(& &1.id)
    {firsts, Map.new(providers, &{&1.id, Map.fetch!(groups, key(&1)).id})}
  end

  defp key(%Connection{provider_kind: kind} = provider) when is_binary(kind),
    do: identity(provider)

  defp key(%Connection{id: id}), do: {:alone, id}

  defp added(%Connection{} = provider),
    do: {DateTime.to_unix(provider.inserted_at, :microsecond), provider.id}

  @doc """
  The providers a run waits for in a key group (`dispatch_runs.model_provider_ids`): the
  head, then each other member with at least one key, by its row as loaded with its
  secret's values. A member with no key is left out: the claim's filter counts a provider
  with no key as one that is not cooling (`Apiary.ModelKeys.claimable/1`).
  """
  @spec waiting_ids([Connection.t()]) :: [Ecto.UUID.t()]
  # shortcut: the head stays first even with no key, as the code that leaves out stopped
  # providers reads the first id as the choice's; the claim's filter then passes the run
  # at each claim. Replace when that code reads the choice's provider another way.
  def waiting_ids([head | others]),
    do: [head.id | for(%Connection{secret: %{values: [_ | _]}} = c <- others, do: c.id)]

  @doc """
  The row ids of the key group of each provider of `ids` for the workspace
  `workspace_id` of the organisation `organisation_id`, as `members/3` orders them, by
  the provider's row id; a provider that is not a model provider of the organisation's
  chain has none. The head is always kept. A `workspace_id` of nil, for a workspace not
  yet made, keeps only the head and the members for every workspace. With `keyed: true`,
  only the head and the members with at least one key (`waiting_ids/1`). Read without a
  lock; the integrity codes are not checked: a claim checks them.
  """
  @spec member_ids(Ecto.UUID.t(), Ecto.UUID.t() | nil, [Ecto.UUID.t()], keyword) ::
          %{Ecto.UUID.t() => [Ecto.UUID.t()]}
  def member_ids(organisation_id, workspace_id, ids, opts \\ [])
  def member_ids(_organisation_id, _workspace_id, [], _opts), do: %{}

  def member_ids(organisation_id, workspace_id, ids, opts) do
    keyed = from v in Value, where: v.secret_id == parent_as(:member).secret_id

    query =
      from h in Connection,
        join: c in Connection,
        as: :member,
        on: ^same_as_head(),
        where: h.id in ^Enum.uniq(ids) and h.organisation_id == ^organisation_id,
        where: not is_nil(h.provider_kind) and h.chain == "organisation",
        select: {h.id, c.id, c.inserted_at}

    query = serving(query, workspace_id)

    query =
      if Keyword.get(opts, :keyed, false),
        do: from([h, c] in query, where: c.id == h.id or exists(keyed)),
        else: query

    query
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {head, rows} ->
      others =
        rows
        |> Enum.reject(&(elem(&1, 1) == head))
        |> Enum.sort_by(fn {_head, id, at} -> {DateTime.to_unix(at, :microsecond), id} end)
        |> Enum.map(&elem(&1, 1))

      {head, [head | others]}
    end)
  end

  # The join of a member `c` to its head `h`: each field of `identity/1` equal.
  defp same_as_head do
    Enum.reduce(@shared, dynamic(true), fn field, same ->
      dynamic([h, c], ^same and field(c, ^field) == field(h, ^field))
    end)
  end

  # The members of `query` that serve the workspace `workspace_id`: the head, and those
  # for every workspace or that list it; for a workspace not yet made (nil), the head and
  # those for every workspace.
  defp serving(query, nil),
    do: from([h, c] in query, where: c.id == h.id or c.applies_to == "all")

  defp serving(query, workspace_id) do
    lists =
      from w in ConnectionWorkspace,
        where: w.connection_id == parent_as(:member).id and w.workspace_id == ^workspace_id

    from([h, c] in query, where: c.id == h.id or c.applies_to == "all" or exists(lists))
  end
end
