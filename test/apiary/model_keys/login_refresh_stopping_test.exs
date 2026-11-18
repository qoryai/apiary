defmodule Apiary.ModelKeys.LoginRefreshStoppingTest do
  # A node that is stopping (`:init.get_status/0` returns `{:stopping, _}`) starts no refresh:
  # a refresh that starts during the stop can be killed at 40 seconds after the SIGTERM,
  # before its call and its writes end. The state is the whole node's, so these tests are
  # not async and set the test function `stopping:` of `Apiary.ModelKeys.Login`, which
  # replaces the real check.
  use Apiary.DataCase, async: false

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Connections
  alias Apiary.Connections.Connection
  alias Apiary.ModelKeys.{Login, LoginRefresh}

  @moduletag needs: [:factory, :secrets]

  @day 86_400

  setup do
    previous = Application.get_env(:apiary, Login, [])
    on_exit(fn -> Application.put_env(:apiary, Login, previous) end)
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp stopping!(stopping?) do
    previous = Application.get_env(:apiary, Login, [])
    Application.put_env(:apiary, Login, Keyword.put(previous, :stopping, fn -> stopping? end))
  end

  defp login!(scope, expires_in) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [
          %{value_id: "main", value: login_paste(tokens: login_tokens(expires_in: expires_in))}
        ]
      })

    provider = Repo.get!(Connection, provider.id)
    {provider, key_value!(provider, "main").id}
  end

  defp stub! do
    test = self()

    Req.Test.stub(LoginRefresh, fn conn ->
      send(test, :requested)
      Req.Test.json(conn, %{"access_token" => "x", "refresh_token" => "y"})
    end)
  end

  test "a due refresh takes no lease and makes no call, and serves a valid token",
       %{scope: scope} do
    {provider, id} = login!(scope, 60)
    stub!()
    stopping!(true)

    for trigger <- [{:run, "run-1"}, :schedule] do
      assert {:ok, access, _at} = Login.access_token(provider, id, trigger: trigger)
      assert is_binary(access) and access != "x"
    end

    refute_received :requested
    assert %Login{lease_id: nil, refreshed_at: nil, failures: 0} = Repo.get!(Login, id)
  end

  test "an expired token is :unavailable", %{scope: scope} do
    {provider, id} = login!(scope, -60)
    stub!()
    stopping!(true)

    assert Login.access_token(provider, id, trigger: {:run, "run-1"}) == {:error, :unavailable}
    refute_received :requested
    assert %Login{lease_id: nil} = Repo.get!(Login, id)
  end

  test "the same refresh is made once the node is not stopping", %{scope: scope} do
    {provider, id} = login!(scope, -60)
    stub!()
    stopping!(false)

    assert {:ok, "x", _at} = Login.access_token(provider, id, trigger: {:run, "run-1"})
    assert_received :requested
  end

  test "the real check does not see a node that runs as stopping", %{scope: scope} do
    {provider, id} = login!(scope, -60)
    stub!()
    refute match?({:stopping, _}, :init.get_status())

    assert {:ok, "x", _at} = Login.access_token(provider, id, trigger: {:run, "run-1"})
  end

  test "the sweep returns no key", %{scope: scope} do
    {_provider, id} = login!(scope, 3600)

    Repo.update_all(from(l in Login, where: l.secret_value_id == ^id),
      set: [signed_in_at: DateTime.add(DateTime.utc_now(), -8 * @day)]
    )

    stopping!(false)
    assert [{_provider, ^id}] = Login.sweep_due(5)
    stopping!(true)
    assert Login.sweep_due(5) == []
  end
end
