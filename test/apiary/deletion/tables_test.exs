defmodule Apiary.Deletion.TablesTest do
  # The walk over the tables that hold an organisation's rows, held to the database's
  # schema: a table added later fails here until `Apiary.Deletion.Tables` or the edition's
  # list names it, in its place.
  use Apiary.Deletion.TablesCase, async: true
end
