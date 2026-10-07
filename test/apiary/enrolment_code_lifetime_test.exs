defmodule Apiary.EnrolmentCodeLifetimeTest do
  # Not async: it changes the application's configuration, which every test reads.
  use Apiary.DataCase, async: false

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.AccessKeys

  setup do
    previous = Application.get_env(:apiary, AccessKeys)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:apiary, AccessKeys)
  defp restore(previous), do: Application.put_env(:apiary, AccessKeys, previous)

  test "a code lives 15 minutes, fixed: no configuration changes it" do
    Application.delete_env(:apiary, AccessKeys)
    assert AccessKeys.code_ttl_minutes() == 15

    for configured <- [5, 600, 0, "10"] do
      Application.put_env(:apiary, AccessKeys, code_ttl_minutes: configured)
      assert AccessKeys.code_ttl_minutes() == 15, inspect(configured)
    end

    %{scope: scope} = sign_up_fixture()
    {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node_fixture(scope), %{})
    assert DateTime.diff(row.expires_at, row.inserted_at, :second) in (15 * 60 - 1)..(15 * 60)
  end
end
