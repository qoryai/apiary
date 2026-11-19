defmodule Apiary.ModelKeys.LoginLeakTest do
  # No token and no account id of a sign-in reaches a log line of any level, an audit entry
  # or a page, through the claim, the background refresh and the run's page that says why a
  # run waits; and that page reads a sign-in's row alone, so a value that cannot be
  # decrypted, or a run whose work item is gone, never makes it raise. The log level is the
  # node's, so the test is not async (`Apiary.DebugLog`).
  use Apiary.DataCase, async: false
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.DebugLog
  import Apiary.DispatchedRunsFixtures
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, ModelKeys}
  alias Apiary.Audit.Entry
  alias Apiary.Connections.Connection
  alias Apiary.Dispatches.{DispatchRun, RunSettings}
  alias Apiary.ModelKeys.{Login, LoginRefresh, LoginRefreshJob}
  alias Apiary.Runs.Waiting
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]

  @body ~s({"version":1,"time":"2026-11-18T12:00:00Z"})

  setup do
    %{scope: scope} = sign_up_fixture()
    ctx = scope |> handover_place_fixture(allow_secrets: true) |> Map.put(:scope, scope)

    old = login_tokens(expires_in: 3600, tag: "old")
    renewed = login_tokens(tag: "renewed")

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [%{value_id: "main", value: device_login(tokens: old)}]
      })

    {:ok, _choice} =
      Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
        provider: provider.public_id,
        runtime: "codex",
        model: "gpt-6-sol"
      })

    test = self()

    Req.Test.stub(LoginRefresh, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "access_token" => renewed.access_token,
        "refresh_token" => renewed.refresh_token
      })
    end)

    provider = Repo.get!(Connection, provider.id)
    value = Repo.one!(from v in Value, where: v.secret_id == ^provider.secret_id)

    {1, _rows} =
      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id),
        set: [signed_in_at: DateTime.add(DateTime.utc_now(), -3600)]
      )

    secrets = [
      old.access_token,
      old.refresh_token,
      old.account_id,
      renewed.access_token,
      renewed.refresh_token,
      renewed.account_id
    ]

    Map.merge(ctx, %{provider: provider, value: value, secrets: secrets})
  end

  defp queued!(ctx) do
    work_item = work_item_fixture(ctx.scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    queued
  end

  defp audit_text, do: Repo.all(Entry) |> Enum.map_join("\n", &inspect/1)

  test "the claim, the job and the run's page have no token or account id in any log", ctx do
    queued = queued!(ctx)

    {waiting, log} =
      with_debug_log(fn ->
        assert {:ok, :none} = walked_claim(ctx.key, Dispatches.now(), @body)
        waiting = Repo.get!(DispatchRun, queued.id)

        assert {:refreshing, _public_id, %{identity: "OpenAI subscription · dana@example.com"}} =
                 Waiting.reason(waiting)

        assert_enqueued(worker: LoginRefreshJob)
        # The queue also holds the jobs of the workspace's set up; the refresh is one of them.
        assert %{failure: 0, discard: 0, cancelled: 0} =
                 Oban.drain_queue(queue: :default, with_safety: false)

        assert {:ok, %{registered: _run}} = walked_claim(ctx.key, Dispatches.now(), @body)
        waiting
      end)

    assert waiting.state == :waiting
    refute_secrets(log, ctx.secrets)
    refute_secrets(audit_text(), ctx.secrets)
  end

  describe "the page's read" do
    test "never decrypts a token: a value that cannot be decrypted still gives its row's state",
         ctx do
      queued = queued!(ctx)
      assert {:ok, :none} = walked_claim(ctx.key, Dispatches.now(), @body)
      waiting = Repo.get!(DispatchRun, queued.id)

      {1, _rows} =
        Repo.update_all(from(v in Value, where: v.id == ^ctx.value.id),
          set: [nonce: :crypto.strong_rand_bytes(12)]
        )

      Repo.update_all(from(l in Login, where: l.secret_value_id == ^ctx.value.id),
        set: [lease_id: Ecto.UUID.generate(), lease_until: DateTime.add(DateTime.utc_now(), 30)]
      )

      {reason, log} = with_debug_log(fn -> Waiting.reason(waiting) end)

      assert {:refreshing, public_id, %{id: row_id, identity: identity}} = reason
      assert public_id == ctx.provider.public_id
      assert row_id == ctx.value.id
      assert identity == "OpenAI subscription · dana@example.com"
      refute_secrets(log, ctx.secrets)

      now = DateTime.utc_now()
      before = DateTime.add(now, 3 * 3600)
      keys = ModelKeys.claim_keys(ctx.provider, now, expires_before: before, decrypt: false)
      assert Map.new(keys, &{&1.value_id, &1.blocked}) == %{"main" => :refreshing}
    end

    test "reads no horizon, and does not raise, for a run whose work item or workspace is gone" do
      run = %DispatchRun{
        step: "explore",
        workspace_id: Ecto.UUID.generate(),
        work_item_id: Ecto.UUID.generate()
      }

      assert RunSettings.horizon_for(run, DateTime.utc_now()) == nil
      assert RunSettings.horizon_for(%{run | work_item_id: nil}, DateTime.utc_now()) == nil
      assert RunSettings.horizon_for(%{run | step: "other"}, DateTime.utc_now()) == nil
    end
  end
end
