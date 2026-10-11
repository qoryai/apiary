defmodule Apiary.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Apiary.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Apiary.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Apiary.DataCase
    end
  end

  setup tags do
    Apiary.DataCase.setup_sandbox(tags)
    Apiary.DataCase.setup_features(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags: an owner of the test's own, whose
  connection is checked in, and everything it wrote rolled back, as the test ends.

  In a module whose `setup_all` set up a module's sandbox (`setup_module_sandbox/2`), the
  context has `:module_sandbox`, and the test starts no owner of its own: it writes on the
  module's connection, inside a savepoint (`SAVEPOINT`), which is rolled back as it ends
  (`ROLLBACK TO SAVEPOINT`, then `RELEASE SAVEPOINT`). What the test wrote is gone; what
  the module's `setup_all` made stays for the next test. Such a test must run under the
  features the module's were made under: one whose `with_features:` gives others raises.
  """
  def setup_sandbox(%{module_sandbox: %{features: features}} = tags) do
    if features(tags) != features do
      raise ArgumentError,
            "#{inspect(tags[:test])} runs under the features " <>
              "#{inspect(features(tags))}, and what its module's setup_all made was made " <>
              "under #{inspect(features)}: give it its own module, which makes it for each " <>
              "test (cast: :test)"
    end

    savepoint = "test_#{System.unique_integer([:positive])}"
    sandbox_query!("SAVEPOINT #{savepoint}")

    on_exit(fn ->
      sandbox_query!("ROLLBACK TO SAVEPOINT #{savepoint}")
      sandbox_query!("RELEASE SAVEPOINT #{savepoint}")
    end)
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Apiary.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Sets up, from a module's `setup_all`, one sandbox for the whole module, and makes in it
  what its tests share, once: `make`, a function that returns a map (or a keyword list)
  the tests find in their context. Returns that map with `:module_sandbox`, which the
  module's `setup_all` returns, so each test runs inside a savepoint of the module's
  connection instead of with an owner of its own (`setup_sandbox/1`):

      setup_all context do
        Apiary.DataCase.setup_module_sandbox(context, fn -> %{shared: make_shared()} end)
      end

  The owner of the module's connection is a process of its own, as a test's is
  (`Ecto.Adapters.SQL.Sandbox.start_owner!/2`), in the shared mode: every process of the
  module's tests, a LiveView under test or a `Task` among them, writes on that
  connection. Its ownership does not time out while the module runs. As the module ends
  the connection is checked in, which rolls back everything the module wrote.

  `make` runs under the features of the module's `@moduletag with_features:`, else the
  suite's, as a test's own setup does (`setup_features/1`); a test whose features differ
  raises. The module must not be async.

  `setup_all` runs in a process of its own, which no test is, and a test's processes do
  not have it among their `$callers`: whatever `make` set in its process, an edition's
  stub (`Apiary.Edition.put_test_stub/1`) or another entry of the process dictionary, a
  test does not see, and must set again in its own `setup`. What lives in the application
  environment, the features among it, is the whole node's: each test sets it again in
  its own setup, as every test does (`setup_features/1`).
  """
  def setup_module_sandbox(context, make) when is_function(make, 0) do
    if context[:async] do
      raise ArgumentError,
            "a module's sandbox is shared by its tests: the module must not be async"
    end

    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Apiary.Repo,
        shared: true,
        ownership_timeout: :infinity
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    features = features(context)
    previous = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, features)

    made =
      try do
        Map.new(make.())
      after
        Application.put_env(:apiary, :features, previous)
      end

    Map.put(made, :module_sandbox, %{owner: owner, features: features})
  end

  # The features a test or a module runs under: its `with_features:`, else the suite's.
  defp features(%{with_features: features}) when is_list(features) do
    {:ok, features} = Apiary.Features.parse(Enum.map_join(features, ",", &to_string/1))
    Enum.sort(features)
  end

  defp features(_tags), do: Enum.sort(Apiary.Features.enabled())

  # A statement of its own on the module's connection: not wrapped in the savepoint the
  # sandbox puts around each statement outside a transaction, whose release would
  # release the test's savepoint with it.
  defp sandbox_query!(sql),
    do: Ecto.Adapters.SQL.query!(Apiary.Repo, sql, [], sandbox_subtransaction: false)

  @doc """
  Switches the instance's features for one test: `@tag with_features: [:observability]`
  runs it as an instance launched with `QORY_FEATURES=observability`, and puts back what
  the suite runs under afterwards. The features are the whole node's, so the test must not
  be async. Its features being its own, `Apiary.TestSetup.start!/1` runs it only where
  the suite has every feature.

  The other tag, `@tag needs: :security` (or `@moduletag`), marks a test that exercises a
  feature; `Apiary.TestSetup.start!/1` leaves it out when the suite runs without that
  feature.
  """
  def setup_features(%{with_features: features} = tags) when is_list(features) do
    if features == [] do
      raise ArgumentError, "@tag with_features: [] would be every feature; list the ones meant"
    end

    if tags[:async] do
      raise ArgumentError,
            "@tag with_features: changes the whole node, so the test must not be async"
    end

    previous = Application.get_env(:apiary, :features)
    {:ok, features} = Apiary.Features.parse(Enum.map_join(features, ",", &to_string/1))
    Application.put_env(:apiary, :features, features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
  end

  def setup_features(_tags), do: :ok

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
