defmodule ApiaryPro.Deletion.TablesTest do
  # The walk over the tables that hold an organisation's rows, the edition's before the core's,
  # held to the schema of a database migrated with both: the edition's tables fail here until
  # `ApiaryPro.Deletion.Tables` names them, in their place. The account suspensions, the
  # instance's branding and who may sign up hold no organisation's rows.
  use Apiary.Deletion.TablesCase,
    async: true,
    instance_tables: ~w(account_suspensions instance_branding instance_sign_up)
end
