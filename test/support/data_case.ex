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
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Apiary.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Switches the instance's features for one test: `@tag with_features: [:observability]`
  runs it as an instance launched with `QORY_FEATURES=observability`, and puts back what
  the suite runs under afterwards. The features are the whole node's, so the test must not
  be async.

  The other tag, `@tag needs: :security` (or `@moduletag`), marks a test that exercises a
  feature; `test/test_helper.exs` leaves it out when the suite runs without that feature.
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
