defmodule ApiaryWeb.Contract.EventsRateLimitTest do
  # The limit comes from the application environment, which every test shares.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures

  setup do
    config = Application.get_env(:apiary, Apiary.Runs.RateLimit)
    Application.put_env(:apiary, Apiary.Runs.RateLimit, rate: 0, burst: 2)
    on_exit(fn -> Application.put_env(:apiary, Apiary.Runs.RateLimit, config) end)
  end

  test "a key over its rate is 429 with Retry-After; another key is not; an unsigned request spends nothing" do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = access_key_fixture(scope)
    %{access_key: other, secret: other_secret} = access_key_fixture(scope)
    {_subject, batch} = first_events()

    # Refused before the limit is looked at: these spend no token.
    for _ <- 1..5 do
      assert build_conn() |> signed_post(key.key_id, "not the secret", batch) |> response(401)
    end

    for _ <- 1..2 do
      assert build_conn() |> signed_post(key.key_id, secret, batch) |> response(202)
    end

    conn = signed_post(build_conn(), key.key_id, secret, batch)
    assert json_response(conn, 429) == %{"error" => "rate_limited"}
    assert get_resp_header(conn, "retry-after") == ["1"]

    assert build_conn() |> signed_post(other.key_id, other_secret, batch) |> response(202)
  end

  test "a refused batch spends a token like any other verified request" do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = access_key_fixture(scope)

    for _ <- 1..2 do
      assert build_conn() |> signed_post(key.key_id, secret, "[]") |> response(400)
    end

    assert build_conn() |> signed_post(key.key_id, secret, "[]") |> response(429)
  end
end

defmodule ApiaryWeb.Contract.EventsUnavailableTest do
  # Breaks a table for the length of a test, inside the test's own transaction;
  # not async, so no other test waits on the table meanwhile.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Repo

  test "a batch that cannot be stored is 503, never 500, and the log has no message of Postgres" do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = access_key_fixture(scope)
    {_subject, batch} = first_events()

    Repo.query!("ALTER TABLE deliveries ADD CONSTRAINT refuse_all CHECK (status = 0) NOT VALID")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn = signed_post(build_conn(), key.key_id, secret, batch)
        assert json_response(conn, 503) == %{"error" => "unavailable"}
        assert get_resp_header(conn, "x-qory-configuration") == []
      end)

    assert log =~ "could not be stored: Postgrex.Error"
    refute log =~ "refuse_all"
    assert Repo.aggregate(Apiary.Runs.Run, :count) == 0
  end
end
