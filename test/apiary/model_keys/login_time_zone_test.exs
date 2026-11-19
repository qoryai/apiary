defmodule Apiary.ModelKeys.LoginTimeZoneTest do
  # `retry_at` and `lease_until` are `timestamp` columns without a time zone that hold UTC
  # wall times. The database's clock is compared with them, and written to `lease_until`,
  # as `timezone('utc', clock_timestamp())`, whatever `TimeZone` the session has.
  use Apiary.DataCase, async: true

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Connections
  alias Apiary.Connections.Connection
  alias Apiary.ModelKeys.{Login, LoginRefresh}

  @moduletag needs: [:factory, :secrets]

  setup do
    %{scope: scope} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [%{value_id: "main", value: device_login(tokens: login_tokens(expires_in: 60))}]
      })

    %{provider: provider, id: key_value!(provider, "main").id}
  end

  # Moves the login's times, as seconds from now (negative for the past), and nil for none.
  defp set_login!(id, changes) do
    changes =
      for {field, seconds} <- changes do
        {field, seconds && DateTime.add(DateTime.utc_now(), seconds)}
      end

    Repo.update_all(from(l in Login, where: l.secret_value_id == ^id), set: changes)
  end

  defp access_token(provider, id, opts \\ []),
    do:
      Login.access_token(
        Repo.get!(Connection, provider.id),
        id,
        [trigger: {:run, "run-1"}] ++ opts
      )

  # Answers the refresh with `body`, and sends the test the login's `lease_until` as it is
  # while the request is made.
  defp stub!(id, body) do
    test = self()

    Req.Test.stub(LoginRefresh, fn conn ->
      send(test, {:request, Repo.get!(Login, id).lease_until})
      Req.Test.json(conn, body)
    end)
  end

  defp fresh do
    tokens = login_tokens(tag: "fresh")
    %{"access_token" => tokens.access_token, "refresh_token" => tokens.refresh_token}
  end

  test "a retry_at in the future holds the refresh in a time zone ahead of UTC", ctx do
    Repo.query!("SET LOCAL TimeZone = 'Asia/Tokyo'")
    set_login!(ctx.id, retry_at: 60)
    stub!(ctx.id, fresh())

    assert {:ok, _token, _expires_at} = access_token(ctx.provider, ctx.id)
    refute_received {:request, _lease_until}
  end

  test "a retry_at in the past lets the refresh run in a time zone behind UTC", ctx do
    Repo.query!("SET LOCAL TimeZone = 'America/Los_Angeles'")
    set_login!(ctx.id, retry_at: -60)
    stub!(ctx.id, fresh())

    assert {:ok, _token, _expires_at} = access_token(ctx.provider, ctx.id)
    assert_received {:request, _lease_until}
  end

  test "a lease that is live holds the refresh in a time zone ahead of UTC", ctx do
    Repo.query!("SET LOCAL TimeZone = 'Asia/Tokyo'")

    Repo.update_all(from(l in Login, where: l.secret_value_id == ^ctx.id),
      set: [lease_id: Ecto.UUID.generate(), lease_until: DateTime.add(DateTime.utc_now(), 30)]
    )

    stub!(ctx.id, fresh())

    assert {:ok, _token, _expires_at} = access_token(ctx.provider, ctx.id, wait: 100, poll: 20)
    refute_received {:request, _lease_until}
  end

  test "the lease ends 75 seconds from the database's time, in any time zone", ctx do
    Repo.query!("SET LOCAL TimeZone = 'Asia/Tokyo'")
    stub!(ctx.id, fresh())

    assert {:ok, _token, _expires_at} = access_token(ctx.provider, ctx.id)
    assert_received {:request, lease_until}
    assert abs(DateTime.diff(lease_until, DateTime.add(Login.db_now(), 75), :second)) < 5
  end

  test "the sweep skips a login with a retry_at in the future, in a time zone ahead of UTC",
       ctx do
    Repo.query!("SET LOCAL TimeZone = 'Asia/Tokyo'")
    set_login!(ctx.id, signed_in_at: -8 * 86_400, refreshed_at: nil, retry_at: 60)
    assert Login.sweep_due(10) == []

    set_login!(ctx.id, retry_at: -60)
    assert [{_provider, id}] = Login.sweep_due(10)
    assert id == ctx.id
  end
end
