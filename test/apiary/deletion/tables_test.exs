defmodule Apiary.Deletion.TablesTest do
  # The walk over the tables that hold an organisation's rows, held to the database's
  # schema: a table added later fails here until `Apiary.Deletion.Tables` or the edition's
  # list names it, in its place.
  use Apiary.Deletion.TablesCase, async: true

  test "a session's key windows go before its record, and the record before what it names" do
    tables = Apiary.Deletion.Tables.tables()
    place = fn table -> Enum.find_index(tables, &(&1 == table)) end

    assert place.("session_key_windows") < place.("session_records")

    for parent <- ~w(runs dispatch_runs work_items targets workspaces) do
      assert place.("session_records") < place.(parent), parent
    end

    assert "session_key_windows" in Apiary.Deletion.Tables.workspace_tables()
    assert "session_records" in Apiary.Deletion.Tables.workspace_tables()
  end
end
