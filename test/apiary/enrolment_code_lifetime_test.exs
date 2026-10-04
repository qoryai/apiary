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

  defp configure(minutes), do: Application.put_env(:apiary, AccessKeys, code_ttl_minutes: minutes)

  test "a code lives 15 minutes unless configured, and never longer" do
    Application.delete_env(:apiary, AccessKeys)
    assert AccessKeys.code_ttl_minutes() == 15

    for {configured, held} <- [{5, 5}, {15, 15}, {16, 15}, {1440, 15}, {0, 1}, {-3, 1}] do
      configure(configured)
      assert AccessKeys.code_ttl_minutes() == held, "#{configured}"
    end

    for unusable <- ["10", 2.5, nil] do
      configure(unusable)
      assert AccessKeys.code_ttl_minutes() == 15
    end
  end

  test "a code made under a longer configuration still expires within 15 minutes" do
    configure(600)
    %{scope: scope} = sign_up_fixture()

    {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node_fixture(scope), %{})
    assert DateTime.diff(row.expires_at, row.inserted_at, :second) <= 15 * 60
  end
end
