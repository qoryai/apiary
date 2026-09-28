defmodule Apiary.Deletion.TablesCase do
  @moduledoc """
  The test of `Apiary.Deletion.Tables` against the database's schema, for any edition: a
  module that `use`s this case gets the tests, run over the walk of the edition it is
  built with and the database its migrations made. A table added later, by the core or
  by an edition, fails them until it is listed, in its place.

      use Apiary.Deletion.TablesCase, instance_tables: ~w(my_edition_settings)

  `instance_tables:` names the edition's own tables of the instance, beside the core's
  (`organisations`, `users`, `users_tokens`, `purged_organisations`, `instance_settings`
  and Oban's), which hold no organisation's rows and are not on the list.
  """

  use ExUnit.CaseTemplate

  alias Apiary.Repo

  @instance_tables ~w(organisations users users_tokens purged_organisations instance_settings
                      oban_jobs oban_peers)

  using opts do
    quote do
      alias Apiary.Deletion.Tables

      import Apiary.Deletion.TablesCase, only: [tables_with: 1, foreign_keys: 0]

      @instance_tables Apiary.Deletion.TablesCase.instance_tables() ++
                         Keyword.get(unquote(opts), :instance_tables, [])

      test "every table with an organisation_id column is on the list, and nothing else is" do
        assert Enum.sort(Tables.tables()) == Enum.sort(tables_with("organisation_id"))
        assert Enum.uniq(Tables.tables()) == Tables.tables()
      end

      test "the workspace's tables are every table with a workspace_id column, in the same order" do
        assert Enum.sort(Tables.workspace_tables()) == Enum.sort(tables_with("workspace_id"))

        # The organisation's own tables, without a workspace_id, are the rest of the list,
        # and the workspace's keep their places among them.
        organisation_only = tables_with("organisation_id") -- tables_with("workspace_id")

        assert Enum.sort(Tables.tables() -- Tables.workspace_tables()) ==
                 Enum.sort(organisation_only)

        assert Tables.workspace_tables() == Tables.tables() -- organisation_only
      end

      test "the list is in delete order: a table comes before every table it has a key to" do
        order = Tables.tables() |> Enum.with_index() |> Map.new()

        for {child, parent} <- foreign_keys(),
            Map.has_key?(order, child),
            Map.has_key?(order, parent),
            child != parent do
          assert order[child] < order[parent],
                 "#{child} has a key to #{parent}, so it is deleted before it"
        end
      end

      test "the instance's own tables are not on it" do
        for table <- @instance_tables do
          refute table in Tables.tables(), "#{table} is the instance's, of no organisation"
        end
      end
    end
  end

  setup tags do
    Apiary.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc "The core's tables of the instance, which hold no organisation's rows."
  @spec instance_tables() :: [String.t()]
  def instance_tables, do: @instance_tables

  @doc "The base tables of the public schema that have a column named `column`."
  @spec tables_with(String.t()) :: [String.t()]
  def tables_with(column) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.table_name
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema AND t.table_name = c.table_name
        WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE'
          AND c.column_name = $1
        """,
        [column]
      )

    List.flatten(rows)
  end

  @doc "Every foreign key of the public schema, as `{table with the key, table it names}`."
  @spec foreign_keys() :: [{String.t(), String.t()}]
  def foreign_keys do
    %{rows: rows} =
      Repo.query!("""
      SELECT conrelid::regclass::text, confrelid::regclass::text
      FROM pg_constraint
      WHERE contype = 'f' AND connamespace = 'public'::regnamespace
      """)

    Enum.map(rows, fn [child, parent] -> {child, parent} end)
  end
end
