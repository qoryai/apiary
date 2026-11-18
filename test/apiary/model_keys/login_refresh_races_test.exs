defmodule Apiary.ModelKeys.LoginRefreshRacesTest do
  # The refresh of a model key's sign-in (`Apiary.ModelKeys.Login.access_token/3`) racing
  # callers and changes of the key, each on a connection apart, outside the SQL sandbox,
  # so each commits and each waits on the other's locks as it would in production. Not
  # async: what these tests commit is visible to every other test while they run, and the
  # organisation they make is deleted again before they end.
  #
  # The rules under test:
  #
  #   * one lease for a login: callers at once make one request;
  #   * a login pasted over the key while the call ran drops the result, and the paste stays;
  #   * a key renamed while the call ran keeps the result, under the new name;
  #   * a key deleted while the call ran drops the result, and nothing is left of it;
  #   * the write of an outcome takes the organisation `FOR SHARE`, the keys' secret
  #     `FOR UPDATE`, then the login's row, as the pastes, renames and deletions do, so no
  #     order of them deadlocks.
  use ExUnit.Case, async: false

  # A list in `needs:` is read by this hook (`Apiary.TestSetup`).
  @before_compile Apiary.TestSetup

  import Ecto.Query
  import Apiary.ModelKeysFixtures
  import Apiary.Races

  alias Apiary.Connections
  alias Apiary.Connections.Connection
  alias Apiary.ModelKeys.{Login, LoginRefresh}
  alias Apiary.Repo
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]

  setup_all :clean_up_leftovers
  setup_all :drop_test_database_objects
  setup :setup_races

  # Two tests add what the database refuses with, outside the sandbox: a constraint on
  # the trail, and a trigger on the values. A run that crashed before its `on_exit` left them
  # in place, and every later test in the database would meet them: dropped here first.
  defp drop_test_database_objects(_context) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    drop_test_database_objects()
    Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    :ok
  end

  defp drop_test_database_objects do
    Repo.query!("ALTER TABLE audit_entries DROP CONSTRAINT IF EXISTS model_key_refresh_refused")
    Repo.query!("DROP TRIGGER IF EXISTS refresh_write_refused ON secret_values")
    Repo.query!("DROP FUNCTION IF EXISTS refresh_write_refused()")
    Repo.query!("DROP SEQUENCE IF EXISTS refresh_write_attempts")
  end

  setup do
    %{scope: scope} = sign_up()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [
          %{
            value_id: "main",
            value: login_paste(tokens: login_tokens(tag: "main", expires_in: 60))
          }
        ]
      })

    %{scope: scope, provider: Repo.get!(Connection, provider.id)}
  end

  # The answer of the refresh: tokens of `tag`.
  defp answer(tag) do
    tokens = login_tokens(tag: tag)
    %{"access_token" => tokens.access_token, "refresh_token" => tokens.refresh_token}
  end

  defp stub_answer!(answer) do
    test = self()

    Req.Test.stub(LoginRefresh, fn conn ->
      send(test, :request)
      Req.Test.json(conn, answer)
    end)
  end

  # The refresh waits for the test inside the call, to change the key meanwhile.
  defp stub_held!(answer) do
    test = self()

    Req.Test.stub(LoginRefresh, fn conn ->
      send(test, {:request, self()})

      receive do
        :go -> :ok
      after
        5_000 -> :ok
      end

      Req.Test.json(conn, answer)
    end)
  end

  defp add_key!(scope, provider, name, tag) do
    {:ok, _provider} =
      Connections.add_provider_key(scope, provider, %{
        value_id: name,
        value: login_paste(tokens: login_tokens(tag: tag, expires_in: 60))
      })

    key_id(provider, name)
  end

  defp key_id(provider, name),
    do:
      Repo.one!(
        from v in Value,
          where: v.secret_id == ^provider.secret_id and v.value_id == ^name,
          select: v.id
      )

  # Pastes a login that is due over the key `name`.
  defp paste_due!(scope, provider, name, tag) do
    {:ok, _provider} =
      Connections.update_provider_key(scope, provider, name, %{
        "value_id" => name,
        "value" => login_paste(tokens: login_tokens(tag: tag, expires_in: 60))
      })

    :ok
  end

  defp tokens!(provider, id) do
    {:ok, tokens} = Login.tokens(provider, id)
    tokens
  end

  defp refresh(provider, id),
    do: Login.access_token(provider, id, trigger: {:run, "run-1"}, poll: 20)

  defp requests_made(count \\ 0) do
    receive do
      :request -> requests_made(count + 1)
      {:request, _call} -> requests_made(count + 1)
    after
      0 -> count
    end
  end

  defp entries(provider),
    do:
      Repo.all(
        from e in Apiary.Audit.Entry,
          where:
            e.organisation_id == ^provider.organisation_id and e.action == "model_key.refresh",
          order_by: e.inserted_at
      )

  test "two callers at once make one request and both get the new token", ctx do
    id = key_id(ctx.provider, "main")
    fresh = answer("one-lease")
    test = self()

    Req.Test.stub(LoginRefresh, fn conn ->
      send(test, :request)
      Process.sleep(300)
      Req.Test.json(conn, fresh)
    end)

    for _round <- 1..2 do
      results =
        together([fn -> refresh(ctx.provider, id) end, fn -> refresh(ctx.provider, id) end])

      assert [{:ok, first, _}, {:ok, second, _}] = results
      assert {first, second} == {fresh["access_token"], fresh["access_token"]}
      assert requests_made() == 1
      assert %Login{lease_id: nil, failures: 0} = Repo.get!(Login, id)

      # The next round starts from a login that is due again.
      paste_due!(ctx.scope, ctx.provider, "main", "again")
    end

    assert length(entries(ctx.provider)) == 2
  end

  test "a login pasted while the call ran stays, and the result is dropped", ctx do
    id = key_id(ctx.provider, "main")
    stub_held!(answer("dropped"))

    caller = start(fn -> refresh(ctx.provider, id) end)
    assert_receive {:request, call}, 5_000

    pasted = login_tokens(tag: "pasted")

    {:ok, _provider} =
      Connections.update_provider_key(ctx.scope, ctx.provider, "main", %{
        "value_id" => "main",
        "value" => login_paste(tokens: pasted)
      })

    send(call, :go)

    assert {:ok, access, _at} = Task.await(caller.task, 10_000)
    assert access == pasted.access_token
    assert tokens!(ctx.provider, id).refresh_token == pasted.refresh_token

    assert %Login{generation: 2, lease_id: nil, failures: 0, refreshed_at: nil} =
             Repo.get!(Login, id)

    assert entries(ctx.provider) == []
  end

  test "a paste and the write of an outcome at once leave the paste, in each order", ctx do
    id = key_id(ctx.provider, "main")
    stub_answer!(answer("raced"))
    pasted = login_tokens(tag: "last")

    for _round <- 1..8 do
      paste_due!(ctx.scope, ctx.provider, "main", "before")

      together([
        fn -> refresh(ctx.provider, id) end,
        fn ->
          {:ok, _provider} =
            Connections.update_provider_key(ctx.scope, ctx.provider, "main", %{
              "value_id" => "main",
              "value" => login_paste(tokens: pasted)
            })
        end
      ])

      assert tokens!(ctx.provider, id).refresh_token == pasted.refresh_token
      assert %Login{lease_id: nil} = Repo.get!(Login, id)
    end
  end

  test "a key renamed while the call ran keeps the result under its new name", ctx do
    id = add_key!(ctx.scope, ctx.provider, "spare", "spare")
    fresh = answer("renamed")
    stub_held!(fresh)

    caller = start(fn -> refresh(ctx.provider, id) end)
    assert_receive {:request, call}, 5_000

    {:ok, _provider} =
      Connections.rename_provider_key(ctx.scope, ctx.provider, "spare", "renamed")

    send(call, :go)

    assert {:ok, access, _at} = Task.await(caller.task, 10_000)
    assert access == fresh["access_token"]
    assert key_id(ctx.provider, "renamed") == id
    assert tokens!(ctx.provider, id).refresh_token == fresh["refresh_token"]
    assert %Login{lease_id: nil, failures: 0, refreshed_at: %DateTime{}} = Repo.get!(Login, id)

    assert [%{details: %{"value_id" => "renamed", "outcome" => "refreshed"}}] =
             entries(ctx.provider)
  end

  test "a rename and the write of an outcome at once keep the rotated token, in each order",
       ctx do
    fresh = answer("kept")
    stub_answer!(fresh)
    id = add_key!(ctx.scope, ctx.provider, "r0", "r0")

    for round <- 1..8 do
      paste_due!(ctx.scope, ctx.provider, "r#{round - 1}", "before#{round}")

      together([
        fn -> refresh(ctx.provider, id) end,
        fn ->
          {:ok, _provider} =
            Connections.rename_provider_key(ctx.scope, ctx.provider, "r#{round - 1}", "r#{round}")
        end
      ])

      assert key_id(ctx.provider, "r#{round}") == id
      assert tokens!(ctx.provider, id).refresh_token == fresh["refresh_token"]
      assert %Login{lease_id: nil} = Repo.get!(Login, id)
    end
  end

  test "an entry that cannot be written costs nothing: the rotated token is stored", ctx do
    id = key_id(ctx.provider, "main")
    fresh = answer("no-entry")
    stub_answer!(fresh)

    # The trail refuses the entry of a refresh, as a full disk or a failed statement would.
    Repo.query!("""
    ALTER TABLE audit_entries
      ADD CONSTRAINT model_key_refresh_refused CHECK (action <> 'model_key.refresh') NOT VALID
    """)

    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      drop_test_database_objects()
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(self(), {:result, refresh(ctx.provider, id)})
      end)

    assert_received {:result, {:ok, access, _at}}
    assert access == fresh["access_token"]
    assert tokens!(ctx.provider, id).refresh_token == fresh["refresh_token"]
    assert %Login{lease_id: nil, failures: 0, refreshed_at: %DateTime{}} = Repo.get!(Login, id)
    assert entries(ctx.provider) == []
    assert log =~ "the entry was not written"
    refute log =~ fresh["refresh_token"]
    refute log =~ fresh["access_token"]
  end

  # The database refuses the first `times` writes of a key's value, as a failing disk would.
  defp refuse_writes!(times) do
    Repo.query!("CREATE SEQUENCE refresh_write_attempts")

    Repo.query!("""
    CREATE FUNCTION refresh_write_refused() RETURNS trigger AS $$
    BEGIN
      IF nextval('refresh_write_attempts') <= #{times} THEN
        RAISE EXCEPTION 'the write is refused';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER refresh_write_refused BEFORE UPDATE ON secret_values
      FOR EACH ROW EXECUTE FUNCTION refresh_write_refused()
    """)

    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      drop_test_database_objects()
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end)
  end

  test "a write that fails once is tried again at once, with the token in memory", ctx do
    id = key_id(ctx.provider, "main")
    fresh = answer("retried")
    stub_answer!(fresh)
    refuse_writes!(1)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(self(), {:result, refresh(ctx.provider, id)})
      end)

    assert_received {:result, {:ok, access, _at}}
    assert access == fresh["access_token"]
    assert tokens!(ctx.provider, id).refresh_token == fresh["refresh_token"]

    assert %Login{state: "signed_in", lease_id: nil, failures: 0, refreshed_at: %DateTime{}} =
             Repo.get!(Login, id)

    assert [%{details: %{"outcome" => "refreshed"}}] = entries(ctx.provider)
    assert requests_made() == 1
    assert log =~ "the write failed"
    refute log =~ fresh["refresh_token"]
    refute log =~ fresh["access_token"]
  end

  test "a write that fails twice needs a new sign-in, and no call uses the spent token", ctx do
    id = key_id(ctx.provider, "main")
    old = tokens!(ctx.provider, id)
    fresh = answer("lost")
    stub_answer!(fresh)
    refuse_writes!(2)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(self(), {:result, refresh(ctx.provider, id)})
      end)

    assert_received {:result, {:error, :sign_in_needed}}

    assert %Login{state: "sign_in_needed", sign_in_cause: "token_not_stored", lease_id: nil} =
             Repo.get!(Login, id)

    assert tokens!(ctx.provider, id) == old

    assert [%{details: %{"outcome" => "sign_in_needed", "cause" => "token_not_stored"}}] =
             entries(ctx.provider)

    assert requests_made() == 1
    assert refresh(ctx.provider, id) == {:error, :sign_in_needed}
    assert requests_made() == 0

    for secret <- [fresh["refresh_token"], fresh["access_token"], old.refresh_token],
        do: refute(log =~ secret)
  end

  test "a shutdown signal while the outcome waits for its lock still stores the token", ctx do
    id = key_id(ctx.provider, "main")
    fresh = answer("shutdown")
    stub_answer!(fresh)

    # A change of the key holds the secret's row: the write of the outcome waits for it.
    {held, holder} =
      hold(fn ->
        Repo.one(
          from s in Apiary.Secrets.Secret,
            where: s.id == ^ctx.provider.secret_id,
            lock: "FOR UPDATE",
            select: s.id
        )
      end)

    caller = start(fn -> refresh(ctx.provider, id) end)
    assert_receive :request, 5_000
    waiting!(holder)

    # What the supervisor sends its children when the application stops.
    tasks = Task.Supervisor.children(LoginRefresh.supervisor())
    assert tasks != []
    for task <- tasks, do: Process.exit(task, :shutdown)
    assert Enum.any?(tasks, &Process.alive?/1)

    commit(held)

    assert {:ok, access, _at} = Task.await(caller.task, 10_000)
    assert access == fresh["access_token"]
    assert tokens!(ctx.provider, id).refresh_token == fresh["refresh_token"]
    assert %Login{lease_id: nil, failures: 0} = Repo.get!(Login, id)
  end

  # Waits, in the database, until a backend waits on a lock `holder` holds.
  defp waiting!(holder, left \\ 250) do
    %{rows: rows} =
      Repo.query!(
        "SELECT pid FROM pg_stat_activity WHERE $1 = ANY (pg_blocking_pids(pid))",
        [holder]
      )

    cond do
      rows != [] -> :ok
      left == 0 -> flunk("no backend waited on the held lock")
      true -> Process.sleep(20) && waiting!(holder, left - 1)
    end
  end

  test "a key deleted while the call ran is gone, and the result is dropped", ctx do
    id = add_key!(ctx.scope, ctx.provider, "spare", "spare")
    stub_held!(answer("gone"))

    caller = start(fn -> refresh(ctx.provider, id) end)
    assert_receive {:request, call}, 5_000

    {:ok, _provider} = Connections.delete_provider_key(ctx.scope, ctx.provider, "spare")
    send(call, :go)

    assert Task.await(caller.task, 10_000) == {:error, :not_found}
    assert Repo.get(Value, id) == nil
    assert Repo.get(Login, id) == nil
    assert entries(ctx.provider) == []
  end

  test "a deletion and the write of an outcome at once end, and leave nothing of the key",
       ctx do
    stub_answer!(answer("deleted"))

    for round <- 1..8 do
      name = "d#{round}"
      id = add_key!(ctx.scope, ctx.provider, name, name)

      results =
        together([
          fn -> refresh(ctx.provider, id) end,
          fn -> Connections.delete_provider_key(ctx.scope, ctx.provider, name) end
        ])

      assert [refreshed, {:ok, _provider}] = results
      assert match?({:ok, _access, _at}, refreshed) or refreshed == {:error, :not_found}
      assert Repo.get(Value, id) == nil
      assert Repo.get(Login, id) == nil
    end
  end

  test "a refresh, a paste, a rename and a deletion of a provider at once do not deadlock",
       ctx do
    stub_answer!(answer("many"))

    for round <- 1..5 do
      {:ok, provider} =
        Connections.create_provider(ctx.scope, %{
          provider: "openai-subscription",
          name: "Many #{round}",
          keys: [
            %{
              value_id: "main",
              value: login_paste(tokens: login_tokens(tag: "m", expires_in: 60))
            },
            %{
              value_id: "spare",
              value: login_paste(tokens: login_tokens(tag: "s", expires_in: 60))
            }
          ]
        })

      provider = Repo.get!(Connection, provider.id)
      main = key_id(provider, "main")
      spare = key_id(provider, "spare")
      pasted = login_paste(tokens: login_tokens(tag: "p#{round}"))

      results =
        together([
          fn -> refresh(provider, main) end,
          fn -> refresh(provider, spare) end,
          fn ->
            Connections.update_provider_key(ctx.scope, provider, "main", %{
              "value_id" => "main",
              "value" => pasted
            })
          end,
          fn -> Connections.rename_provider_key(ctx.scope, provider, "spare", "moved") end,
          fn -> Connections.delete_provider(ctx.scope, provider) end
        ])

      # Each side ended: none was chosen as a deadlock's victim.
      assert length(results) == 5
      assert Repo.get(Connection, provider.id) == nil
    end
  end
end
