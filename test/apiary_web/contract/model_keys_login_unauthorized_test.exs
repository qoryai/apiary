defmodule ApiaryWeb.Contract.ModelKeysLoginUnauthorizedTest do
  # The `unauthorized` list of a gateway's model keys report (`POST /v1/runs/<id>/model-keys`)
  # for a run whose model key is a sign-in (`Apiary.ModelKeys.Login`), together with the
  # secrets request that renews the token (`POST /v1/secrets`). A report whose `at` is
  # before the time the run's copy took the token it has now is for an earlier token and
  # marks nothing (`Apiary.ModelKeys.reject/4`); the three ways such a report arrives are
  # one test each. Not async, as the other contract tests of a pool: the features are the
  # whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{Policy, Repo}
  alias Apiary.ModelKeys.{Copy, Login, LoginRefresh, Rejection}
  alias Apiary.Secrets.Value
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: [:factory, :secrets, :observability]
  setup {Apiary.DataCase, :without_registry}

  setup do
    %{scope: scope} = sign_up_fixture()
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example"})
    tokens = login_tokens(expires_in: 3600)

    ctx =
      sealed_run_fixture(scope,
        kind: "openai-subscription",
        keys: [%{value_id: "main", value: device_login(tokens: tokens)}],
        choice: %{runtime: "codex", model: "gpt-6-sol"}
      )

    value = Repo.one!(from v in Value, where: v.secret_id == ^ctx.provider.secret_id)

    # The sign-in is an hour old: a renewal after a 401 may refresh it, and a 401 for its
    # token marks the key only when the report is for the token the run has.
    {1, _rows} =
      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id),
        set: [signed_in_at: DateTime.add(DateTime.utc_now(), -3600)]
      )

    Req.Test.stub(LoginRefresh, fn conn ->
      tokens = login_tokens(tag: "renewed")

      Req.Test.json(conn, %{
        "access_token" => tokens.access_token,
        "refresh_token" => tokens.refresh_token
      })
    end)

    Map.merge(ctx, %{scope: scope, tokens: tokens, value: value})
  end

  defp start(ctx), do: "#{ctx.provider.public_id}-1"

  defp signed(ctx, target, body) do
    {key, seed} = ctx.secrets_key

    signed_post(build_conn(), key.key_id, seed, body,
      target: target,
      content_type: "application/json",
      delivery: nil
    )
  end

  # The secrets request, with the key listed in `unauthorized` when `renew?`.
  defp secrets(ctx, renew? \\ false) do
    members =
      [
        version: 1,
        run_id: ctx.run.node_run_id,
        run_configuration: ctx.attached.digest,
        credentials: [start(ctx)]
      ] ++
        if(renew?, do: [unauthorized: [start(ctx)]], else: []) ++
        [timestamp: SignedRequest.now()]

    signed(ctx, "/v1/secrets", Jason.encode!(Jason.OrderedObject.new(members)))
  end

  defp at(offset),
    do:
      DateTime.utc_now()
      |> DateTime.add(offset)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

  # The model keys report, with a 401 of the run's key at `at`.
  defp report(ctx, at) do
    members = [
      version: 1,
      run_id: ctx.run.node_run_id,
      time: at(0),
      keys: [],
      unauthorized: [%{"credential" => start(ctx), "at" => at}]
    ]

    signed(
      ctx,
      "/v1/runs/#{ctx.run.node_run_id}/model-keys",
      Jason.encode!(Jason.OrderedObject.new(members))
    )
  end

  defp rows, do: Repo.all(Rejection)

  test "the copy keeps when it took the token, and keeps it while the token is the same", ctx do
    assert secrets(ctx).status == 200
    assert [%Copy{login_at: first, login_sealed_at: %DateTime{} = sealed}] = Repo.all(Copy)
    assert first == Repo.one!(Login).signed_in_at

    assert secrets(ctx).status == 200
    assert [%Copy{login_at: ^first, login_sealed_at: ^sealed}] = Repo.all(Copy)

    assert secrets(ctx, true).status == 200
    assert [%Copy{login_at: renewed, login_sealed_at: later}] = Repo.all(Copy)
    assert DateTime.compare(renewed, first) == :gt
    assert DateTime.compare(later, sealed) == :gt
  end

  test "a report sent again after the renewal sealed a newer copy marks nothing", ctx do
    assert secrets(ctx).status == 200
    before_renewal = at(-1)

    # The 401 is for a token an hour old, which the renewal may replace: nothing is marked.
    assert report(ctx, before_renewal).status == 200
    assert rows() == []

    # The renewal refreshes the token and seals it for the run.
    assert secrets(ctx, true).status == 200

    # The gateway sends the same entry again: it is for the token before the renewal.
    assert report(ctx, before_renewal).status == 200
    assert rows() == []

    # A 401 that arrives after the renewal is for the new token, under 5 minutes old.
    assert report(ctx, at(5)).status == 200
    assert [_row] = rows()
  end

  test "a 401 of a request that was in flight before the renewal marks nothing", ctx do
    assert secrets(ctx).status == 200
    in_flight = at(-1)

    assert secrets(ctx, true).status == 200

    # The request began before the renewal and ended with 401 after it: the report comes
    # after the renewal, with an `at` before it.
    assert report(ctx, in_flight).status == 200
    assert rows() == []
  end

  test "a report repeated because the renewal's answer was lost marks nothing", ctx do
    assert secrets(ctx).status == 200
    first_401 = at(-1)

    # The renewal is made and its answer does not reach the gateway: the gateway asks
    # again, is told to wait (the key was refreshed less than 5 minutes ago), and sends
    # its last report again.
    assert secrets(ctx, true).status == 200
    assert secrets(ctx, true).status == 503

    assert report(ctx, first_401).status == 200
    assert rows() == []
  end
end
