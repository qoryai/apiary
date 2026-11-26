defmodule Apiary.Dispatches.LoginClaimStoppingTest do
  # A claim while the node is stopping (`:init.get_status/0` returns `{:stopping, _}`)
  # starts no refresh of a sign-in that expires before the end of the run's time limit,
  # and the run's page shows that the server restarts (`Apiary.Runs.Waiting`). The state
  # is the whole node's, so these tests are not async and set the test function
  # `stopping:` of `Apiary.ModelKeys.Login`, which replaces the real check.
  use Apiary.DataCase, async: false
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.DispatchedRunsFixtures
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches}
  alias Apiary.ModelChoicesFixtures
  alias Apiary.Connections.Connection
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.ModelKeys.{Login, LoginRefresh, LoginRefreshJob}
  alias Apiary.Runs.Waiting

  @moduletag needs: [:factory, :secrets]
  @moduletag :stopping

  @body ~s({"version":1,"time":"2026-11-18T12:00:00Z"})

  setup do
    previous = Application.get_env(:apiary, Login, [])
    on_exit(fn -> Application.put_env(:apiary, Login, previous) end)
    Application.put_env(:apiary, Login, Keyword.put(previous, :stopping, fn -> true end))

    %{scope: scope} = sign_up_fixture()

    ctx =
      scope
      |> handover_place_fixture(allow_secrets: true)
      |> Map.put(:scope, scope)

    stub!()
    ctx
  end

  # Every call to the provider's login server is recorded.
  defp stub! do
    test = self()

    Req.Test.stub(LoginRefresh, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(raw)})
      tokens = login_tokens(tag: "refreshed")

      Req.Test.json(conn, %{
        "access_token" => tokens.access_token,
        "refresh_token" => tokens.refresh_token
      })
    end)
  end

  defp requests(acc \\ []) do
    receive do
      {:request, body} -> requests([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A provider with the key `main`, whose sign-in expires in `expires_in` seconds, chosen
  # at the workspace with the runtime `codex`.
  defp provider!(ctx, expires_in) do
    {:ok, provider} =
      Connections.create_provider(ctx.scope, %{
        provider: "openai-subscription",
        keys: [
          %{value_id: "main", value: device_login(tokens: login_tokens(expires_in: expires_in))}
        ]
      })

    {:ok, _choice} =
      ModelChoicesFixtures.put_choice(ctx.scope, :workspace, %{
        provider: provider.public_id,
        runtime: "codex",
        model: "gpt-6-sol"
      })

    Repo.get!(Connection, provider.id)
  end

  # The login signed in an hour ago, so a new sign-in is not read as just made.
  defp aged!(provider, name) do
    {1, _rows} =
      Repo.update_all(
        from(l in Login, where: l.secret_value_id == ^key_value!(provider, name).id),
        set: [signed_in_at: DateTime.add(DateTime.utc_now(), -3600)]
      )
  end

  defp queued!(ctx) do
    work_item = work_item_fixture(ctx.scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    queued
  end

  defp claim(ctx), do: walked_claim(ctx.key, Dispatches.now(), @body)

  defp waiting!(queued, provider) do
    assert %DispatchRun{state: :waiting} = waiting = Repo.get!(DispatchRun, queued.id)
    assert waiting.model_provider_ids == [provider.id]

    assert Repo.aggregate(from(d in Dispatch, where: d.dispatch_run_id == ^queued.id), :count) ==
             0

    waiting
  end

  test "no refresh is started, and the run's line shows that the server restarts", ctx do
    provider = provider!(ctx, 3600)
    aged!(provider, "main")
    queued = queued!(ctx)

    assert {:ok, :none} = claim(ctx)
    waiting = waiting!(queued, provider)

    assert {:restart, _public_id, %{id: key_id, identity: _line}} = Waiting.reason(waiting)

    assert key_id == key_value!(provider, "main").id
    refute_enqueued(worker: LoginRefreshJob)
    assert requests() == []
  end
end
