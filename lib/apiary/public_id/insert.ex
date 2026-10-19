defmodule Apiary.PublicId.Insert do
  @moduledoc """
  Insert runs an insert that makes a public id (`Apiary.PublicId`) again, with a fresh id,
  when the database refuses it on the unique index of that id, up to `max_tries/0` tries in
  all. The id has 80 random bits, so a collision is rare; without this module it fails the
  insert.

  A refusal counts only when it names the index `<table>_public_id_index`, the one
  `unique_index(:<table>, [:public_id])` makes. Any other constraint, and any other error,
  returns or raises at the first try, as an insert does without this module.

  An id is made in Elixir (`Apiary.PublicId.generate/1`) or by the column's default in the
  database (a function such as `source_item_public_id()`). `insert/2`, `insert!/2` and
  `insert_all/3` put a fresh Elixir-made id into the insert from the second try on; an
  insert that leaves the id to the column's default runs again as it is, and the default
  makes another id. `run/2` is for an insert that builds more than a row, such as one whose
  other fields depend on the id.

  Inside a transaction, a refused insert aborts the transaction in PostgreSQL. Each try
  therefore runs in a savepoint, which a failed try rolls back, so the transaction goes on
  and the next try runs in it. Outside a transaction there is nothing to roll back and no
  savepoint is taken.

  When every try collides, the result of the last try is the result: the same
  `{:error, changeset}` where the changeset declares `unique_constraint(:public_id)`, and
  the same `Ecto.ConstraintError` or `Postgrex.Error`, raised, where it does not. A caller
  that handles the one without this module handles the other with it.
  """

  alias Apiary.{PublicId, Repo}

  @max_tries 3

  @typedoc "A table's name, as `Ecto.Schema` gives it for `:source`, or its schema module."
  @type table :: String.t() | module

  @doc "max_tries/0 is how many times in all an insert runs when its public id collides."
  @spec max_tries() :: pos_integer
  def max_tries, do: @max_tries

  @doc """
  run/2 calls `fun` with the number of the try, 1 first, up to `max_tries/0` tries in
  all, for as long as its result is a refusal on the unique index of `table`'s public id:
  a raised `Ecto.ConstraintError` or `Postgrex.Error`, an `{:error, changeset}` with an
  error of that index on any field, or `{:error, :public_id_taken}`, which `fun` returns
  when it finds the id taken by itself (an insert that does nothing on a conflict, then a
  read). A call of `fun` that is a refusal is rolled back, with whatever it wrote, when the
  caller is in a transaction. The result of the last try is the result.
  """
  @spec run(table, (pos_integer -> result)) :: result when result: term
  def run(table, fun) when is_function(fun, 1), do: attempt(index(table), fun, 1)

  @doc """
  insert/2 inserts `subject`, a changeset or a struct with a public id, by `fun`, which
  takes it and returns what `Repo.insert/1` does; `Repo.insert/1` when `fun` is not given.
  From the second try on, `fun` gets `subject` with a fresh id of the same prefix, so a
  `fun` that derives a field from the id, such as a seal over the row, derives it again.
  A subject whose public id is nil keeps it nil: the column's default makes the id.
  """
  @spec insert(Ecto.Changeset.t() | struct, (Ecto.Changeset.t() | struct -> result)) :: result
        when result: term
  def insert(subject, fun \\ &Repo.insert/1) when is_function(fun, 1) do
    run(table_of(subject), fn
      1 -> fun.(subject)
      _later -> fun.(with_fresh_id(subject))
    end)
  end

  @doc """
  insert!/2 is `insert/2` that returns the struct and raises `Ecto.InvalidChangesetError`
  for an error, as `c:Ecto.Repo.insert!/2` does.
  """
  @spec insert!(Ecto.Changeset.t() | struct, (Ecto.Changeset.t() | struct -> term)) :: struct
  def insert!(subject, fun \\ &Repo.insert/1) do
    case insert(subject, fun) do
      {:ok, struct} ->
        struct

      {:error, %Ecto.Changeset{} = changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  @doc """
  insert_all/3 is `c:Ecto.Repo.insert_all/3` of `rows`, a list of maps, into `schema` or a
  table's name, with `opts`. From the second try on, each row that has a `:public_id` gets
  a fresh one of the same prefix; a row that has none runs again as it is.
  """
  @spec insert_all(table, [map], keyword) :: {non_neg_integer, nil | [term]}
  def insert_all(table, rows, opts \\ []) when is_list(rows) do
    run(table, fn
      1 -> Repo.insert_all(table, rows, opts)
      _later -> Repo.insert_all(table, Enum.map(rows, &with_fresh_id/1), opts)
    end)
  end

  defp attempt(index, fun, number) do
    case guarded(index, fn -> fun.(number) end) do
      {:collision, _result} when number < @max_tries -> attempt(index, fun, number + 1)
      {:collision, {:raised, exception, stacktrace}} -> reraise exception, stacktrace
      {:collision, {:returned, result}} -> result
      {:finished, result} -> result
    end
  end

  # Runs `call` in a savepoint when the caller is in a transaction. A refusal, a raise or
  # an `{:error, _}`, rolls the savepoint back, which also ends the aborted state the
  # database is in after a refused statement.
  defp guarded(index, call) do
    savepoint? = Repo.in_transaction?()
    if savepoint?, do: Repo.query!("SAVEPOINT public_id_try")

    try do
      call.()
    rescue
      exception ->
        stacktrace = __STACKTRACE__
        if savepoint?, do: undo()
        reraise_unless_collision(index, exception, stacktrace)
    else
      result ->
        failed? = match?({:error, _reason}, result)

        if savepoint?,
          do: if(failed?, do: undo(), else: Repo.query!("RELEASE SAVEPOINT public_id_try"))

        if collision?(index, result),
          do: {:collision, {:returned, result}},
          else: {:finished, result}
    end
  end

  defp reraise_unless_collision(index, exception, stacktrace) do
    if collision?(index, exception),
      do: {:collision, {:raised, exception, stacktrace}},
      else: reraise(exception, stacktrace)
  end

  defp undo do
    Repo.query!("ROLLBACK TO SAVEPOINT public_id_try")
    Repo.query!("RELEASE SAVEPOINT public_id_try")
  end

  defp collision?(_index, {:error, :public_id_taken}), do: true

  defp collision?(index, {:error, %Ecto.Changeset{errors: errors}}) do
    Enum.any?(errors, fn {_field, {_message, meta}} ->
      meta[:constraint] == :unique and meta[:constraint_name] == index
    end)
  end

  defp collision?(index, %Ecto.ConstraintError{type: :unique, constraint: index}), do: true

  defp collision?(index, %Postgrex.Error{postgres: %{code: :unique_violation, constraint: index}}),
       do: true

  defp collision?(_index, _other), do: false

  defp index(table), do: table_name(table) <> "_public_id_index"

  defp table_name(table) when is_binary(table), do: table
  defp table_name(schema) when is_atom(schema), do: schema.__schema__(:source)

  defp table_of(%Ecto.Changeset{data: %schema{}}), do: schema
  defp table_of(%schema{}), do: schema

  defp with_fresh_id(%Ecto.Changeset{} = changeset) do
    case Ecto.Changeset.get_field(changeset, :public_id) do
      id when is_binary(id) -> Ecto.Changeset.put_change(changeset, :public_id, fresh(id))
      nil -> changeset
    end
  end

  defp with_fresh_id(%{public_id: id} = struct_or_row) when is_binary(id),
    do: %{struct_or_row | public_id: fresh(id)}

  defp with_fresh_id(struct_or_row), do: struct_or_row

  defp fresh(id) do
    [prefix, _random] = String.split(id, "_", parts: 2)
    PublicId.generate(prefix)
  end
end
