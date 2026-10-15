defmodule Apiary.IntegrationTablesGuardMigrationTest do
  # The guard before the integrations and the stored secrets move to the organisation
  # (`20261016090000_expect_the_integration_tables_empty`): its lock and its count, run on
  # its seven tables by the names they have now, inside the test's transaction, which rolls
  # it all back. The lock is ACCESS EXCLUSIVE until then, so this is not async.
  use Apiary.DataCase, async: false

  @moduletag needs: :secrets

  import Apiary.ConnectionsFixtures
  import Apiary.DescriptionFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, Secrets}

  @guard {20_261_016_090_000, Apiary.Repo.Migrations.ExpectTheIntegrationTablesEmpty,
          "expect_the_integration_tables_empty"}

  # The names the migrations after the guard give its tables.
  @renamed %{
    "workspace_data_keys" => "organisation_data_keys",
    "workspace_connections" => "organisation_connections",
    "connection_targets" => "connection_workspaces"
  }

  setup_all do
    {version, migration, name} = @guard

    unless Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  # The migration's functions, through `apply/3`: its module is loaded from its file in
  # `setup_all`, after this one is compiled.
  defp guard(fun, args \\ []), do: apply(elem(@guard, 1), fun, args)

  # The guard's tables as they are named now: a table a later migration renamed by its new
  # name.
  defp tables_now do
    for table <- guard(:tables) do
      %{rows: [[exists]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", [table])
      if exists, do: table, else: Map.fetch!(@renamed, table)
    end
  end

  # The tables as they are named now, children first.
  defp delete_order do
    now = Map.new(Enum.zip(guard(:tables), tables_now()))

    Enum.map(
      ~w(connection_targets workspace_connections service_definitions integration_releases
         secret_values secrets workspace_data_keys),
      &Map.fetch!(now, &1)
    )
  end

  defp guard! do
    guard(:guard!, [Repo, tables_now()])
  rescue
    error in RuntimeError -> {:refused, error.message}
  end

  # The tables a refusal names as holding rows.
  defp named?(message, table) do
    [_, names] = Regex.run(~r/but the tables? (.+) holds? rows/, message)
    table in String.split(names, [", ", " and "])
  end

  test "the guard's tables are the integrations' and the stored secrets'" do
    assert guard(:tables) ==
             ~w(workspace_connections connection_targets secrets secret_values
                workspace_data_keys integration_releases service_definitions)
  end

  test "it refuses while any of its tables holds a row, naming each that does, and passes when all are empty" do
    %{scope: scope} = sign_up_fixture()

    # A row in each of the seven: a secret with its value and the organisation's data
    # key; a runtime that applies to a repository; a release; a service definition.
    {:ok, _secret} = Secrets.create_secret(scope, %{name: "API_KEY", value: "a value"})
    {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
    {:ok, _runtime} = Connections.put_target(scope, runtime, target!(scope, "acme/shop").id)
    _release = ready_release!(scope, github_description())

    {:ok, _definition} =
      Connections.create_service_definition(scope, %{
        "version" => 1,
        "key" => "status-api",
        "title" => "Status API",
        "hosts" => ["status.example.com"],
        "auth" => %{"scheme" => "bearer", "secret" => "key"},
        "declares" => [%{"id" => "key", "title" => "API key", "name" => "STATUS_API_KEY"}]
      })

    tables = tables_now()
    assert {:refused, message} = guard!()
    for table <- tables, do: assert(named?(message, table), "#{table} is not named")

    # Emptied one by one, children first: each refusal names those still holding rows.
    delete_order = delete_order()
    {last, emptied} = List.pop_at(delete_order, -1)

    for {table, index} <- Enum.with_index(emptied) do
      Repo.query!("DELETE FROM #{table}")
      assert {:refused, message} = guard!()

      for gone <- Enum.take(emptied, index + 1),
          do: refute(named?(message, gone), "#{gone} is named, empty")

      for left <- Enum.drop(delete_order, index + 1),
          do: assert(named?(message, left), "#{left} is not named")
    end

    Repo.query!("DELETE FROM #{last}")
    assert guard!() == :ok
  end

  test "its refusal says what stopped the migrations, naming the tables that hold rows" do
    assert guard(:refusal, [["secrets"]]) ==
             "Qory now keeps the integrations and the stored secrets of an organisation, " <>
               "not of a workspace. This change expects their tables empty, but the table " <>
               "secrets holds rows. The migration changed nothing."

    assert guard(:refusal, [["secrets", "secret_values", "workspace_data_keys"]]) ==
             "Qory now keeps the integrations and the stored secrets of an organisation, " <>
               "not of a workspace. This change expects their tables empty, but the tables " <>
               "secrets, secret_values and workspace_data_keys hold rows. The migration " <>
               "changed nothing."
  end

  test "it takes its tables ACCESS EXCLUSIVE in the transaction it runs in" do
    for table <- delete_order(), do: Repo.query!("DELETE FROM #{table}")

    assert guard!() == :ok

    %{rows: locked} =
      Repo.query!("""
      SELECT c.relname FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
      WHERE l.pid = pg_backend_pid() AND l.mode = 'AccessExclusiveLock' AND l.granted
      """)

    locked = List.flatten(locked)
    for table <- tables_now(), do: assert(table in locked, "#{table} is not locked")
  end
end
