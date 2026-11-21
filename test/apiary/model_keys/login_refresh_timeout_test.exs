defmodule Apiary.ModelKeys.LoginRefreshTimeoutTest do
  # A call that outlasts its limit (`Apiary.ModelKeys.LoginRefresh`) is stopped, with
  # `:brutal_kill`, and is a `timeout`. Not async: the test shortens the limit, which is
  # the node's setting, and the other tests of the refresh would see it.
  use Apiary.DataCase, async: false

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.Audit.Entry
  alias Apiary.Connections
  alias Apiary.Connections.Connection
  alias Apiary.ModelKeys.{Login, LoginRefresh}

  @moduletag needs: [:factory, :secrets]

  test "is stopped at the limit, is a timeout, and writes no log line" do
    %{scope: scope} = sign_up_fixture()
    tokens = login_tokens(expires_in: 120)

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [%{value_id: "main", value: device_login(tokens: tokens)}]
      })

    previous = Application.get_env(:apiary, LoginRefresh)
    Application.put_env(:apiary, LoginRefresh, Keyword.put(previous, :total_timeout, 100))
    on_exit(fn -> Application.put_env(:apiary, LoginRefresh, previous) end)

    fresh = login_tokens(tag: "late")

    Req.Test.stub(LoginRefresh, fn conn ->
      Process.sleep(2_000)
      Req.Test.json(conn, %{"access_token" => fresh.access_token})
    end)

    id = key_value!(provider, "main").id
    plain = Repo.get!(Connection, provider.id)

    log =
      capture_log(fn ->
        send(self(), {:result, Login.access_token(plain, id, trigger: {:run, "run-1"})})
      end)

    assert_received {:result, {:ok, access, _at}}
    assert access == tokens.access_token
    assert log == ""

    assert [%Entry{details: %{"cause" => "timeout"}}] =
             Repo.all(from e in Entry, where: e.action == "model_key.refresh")
  end
end
