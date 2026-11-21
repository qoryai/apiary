defmodule Apiary.ModelKeys.LoginRefreshFeaturesTest do
  # An instance without `secrets`: `Apiary.Access` does not allow `model_key.refresh`, so a
  # refresh that is due makes no call and writes no entry, and the caller gets the stored
  # token while it is valid. Not async: the features are the whole node's.
  use Apiary.DataCase, async: false

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias Apiary.Connections
  alias Apiary.Connections.Connection
  alias Apiary.ModelKeys.{Login, LoginRefresh}

  # A login that expires in `expires_in` seconds, written while every feature was on, then the
  # features switched.
  defp due_login!(scope, features, expires_in \\ 60) do
    previous = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, Apiary.Features.all())
    tokens = login_tokens(expires_in: expires_in)

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [%{value_id: "main", value: device_login(tokens: tokens)}]
      })

    Application.put_env(:apiary, :features, features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
    {Repo.get!(Connection, provider.id), tokens}
  end

  defp stub! do
    test = self()

    Req.Test.stub(LoginRefresh, fn conn ->
      send(test, :requested)
      Req.Test.json(conn, %{"access_token" => "x", "refresh_token" => "y"})
    end)
  end

  @tag with_features: [:observability, :security]
  test "without secrets, a due refresh makes no call, writes no entry and serves the token" do
    %{scope: scope} = sign_up_fixture()
    {provider, tokens} = due_login!(scope, [:observability, :security])
    value = key_value!(provider, "main")
    stub!()

    assert {:ok, access, _at} = Login.access_token(provider, value.id, trigger: {:run, "run-1"})
    assert access == tokens.access_token
    refute_received :requested

    assert Repo.aggregate(
             from(e in Entry, where: e.action == "model_key.refresh"),
             :count
           ) == 0

    assert %Login{lease_id: nil, failures: 0, refreshed_at: nil} = Repo.get!(Login, value.id)
  end

  @tag with_features: [:observability, :security]
  test "without secrets, a token that has expired is unavailable" do
    %{scope: scope} = sign_up_fixture()
    {provider, _tokens} = due_login!(scope, [:observability, :security], -60)
    value = key_value!(provider, "main")
    stub!()

    assert Login.access_token(provider, value.id, trigger: {:run, "run-1"}) ==
             {:error, :unavailable}

    refute_received :requested
  end
end
