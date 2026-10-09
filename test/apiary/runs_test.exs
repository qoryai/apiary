defmodule Apiary.RunsTest do
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Organisations
  alias Apiary.Runs
  alias Apiary.Runs.Run

  setup do
    %{scope: scope_fixture(), other: scope_fixture()}
  end

  test "topics" do
    assert Runs.topic("h") == "runs:h"
    assert Runs.topic("h", "r") == "run:h:r"
  end

  describe "count_alive/1" do
    test "counts the pending and the running runs of the scope's workspace only", %{
      scope: scope,
      other: other
    } do
      for state <- ~w(pending running running succeeded failed timed_out lost closed) do
        run_fixture(scope, %{state: state})
      end

      run_fixture(other, %{state: "running"})

      assert Runs.count_alive(scope) == 3
      assert Runs.count_alive(other) == 1
    end
  end

  describe "get_run!/2 and list_runs/2" do
    test "a run of another workspace is not reachable", %{scope: scope, other: other} do
      run = run_fixture(scope)

      assert Runs.get_run!(scope, run.id).id == run.id
      assert_raise Ecto.NoResultsError, fn -> Runs.get_run!(other, run.id) end
      assert_raise Ecto.NoResultsError, fn -> Runs.get_run!(scope, "not-an-id") end
      assert Runs.list_runs(other) == []
    end

    test "newest first, limited", %{scope: scope} do
      now = DateTime.utc_now()

      [_oldest, middle, newest] =
        for age <- [30, 20, 10] do
          run_fixture(scope, %{inserted_at: DateTime.add(now, -age, :second)})
        end

      assert Enum.map(Runs.list_runs(scope, limit: 2), & &1.id) == [newest.id, middle.id]
      assert length(Runs.list_runs(scope)) == 3
    end
  end

  describe "close_run/2" do
    test "an owner closes a run, and the receiver's question is answered", %{scope: scope} do
      run = run_fixture(scope, %{state: "running"})
      Runs.subscribe(scope)

      refute Runs.closed?(scope.workspace.id, run.run_id)
      assert {:ok, %Run{state: "closed"} = closed} = Runs.close_run(scope, run)

      assert closed.closed_by_id == scope.user.id
      assert closed.closed_at
      assert Runs.closed?(scope.workspace.id, run.run_id)
      assert_receive {:run_changed, %Run{state: "closed"}}
    end

    test "a member closes a run", %{scope: scope} do
      member = member_fixture(scope, :member)
      run = run_fixture(scope)

      assert {:ok, %Run{state: "closed"} = closed} = Runs.close_run(member.scope, run)
      assert closed.closed_by_id == member.user.id
    end

    test "closing twice keeps the first close", %{scope: scope} do
      member = member_fixture(scope, :member)
      run = run_fixture(scope)

      {:ok, first} = Runs.close_run(scope, run)
      Runs.subscribe(scope)
      assert {:ok, again} = Runs.close_run(member.scope, run)

      assert again.closed_at == first.closed_at
      assert again.closed_by_id == scope.user.id
      refute_receive {:run_changed, _}
    end

    test "a member of another workspace gets not found", %{scope: scope, other: other} do
      run = run_fixture(scope, %{state: "running"})

      assert {:error, :not_found} = Runs.close_run(other, run)
      assert Repo.get!(Run, run.id).state == "running"
      refute Runs.closed?(scope.workspace.id, run.run_id)
    end

    test "a caller whose membership is gone is refused", %{scope: scope} do
      member = member_fixture(scope, :member)
      run = run_fixture(scope)
      {:ok, _} = Organisations.remove_member(scope, member.membership.id)

      assert {:error, :forbidden} = Runs.close_run(member.scope, run)
      assert Repo.get!(Run, run.id).state == "pending"
    end

    test "a run a gateway opened is refused: the one who starts a run ends it", %{
      scope: scope
    } do
      Runs.subscribe(scope)

      for state <- Runs.closable_states() do
        run = run_fixture(scope, %{state: state, opened_by: "gateway"})
        refute Runs.closable?(run)

        assert {:error, :ended_by_its_starter} = Runs.close_run(scope, run)

        after_close = Repo.get!(Run, run.id)
        assert after_close.state == state
        assert after_close.closed_at == nil
        assert after_close.closed_by_id == nil
        refute Runs.closed?(scope.workspace.id, run.run_id)
      end

      refute_receive {:run_changed, _}
    end

    test "a run whose credential came from an issuer is refused: the one who starts a run ends it",
         %{scope: scope} do
      Runs.subscribe(scope)

      for state <- Runs.closable_states() do
        run =
          run_fixture(scope, %{state: state, opened_by: "session", credential_from: "issuer"})

        refute Runs.closable?(run)

        assert {:error, :ended_by_its_starter} = Runs.close_run(scope, run)

        after_close = Repo.get!(Run, run.id)
        assert after_close.state == state
        assert after_close.closed_at == nil
        assert after_close.closed_by_id == nil
        refute Runs.closed?(scope.workspace.id, run.run_id)
      end

      refute_receive {:run_changed, _}
    end

    test "a run whose start said issuer after it was read is refused, and its row is unchanged",
         %{scope: scope} do
      stale = run_fixture(scope, %{state: "running", opened_by: "session"})
      assert Runs.closable?(stale)

      Repo.update!(Ecto.Changeset.change(stale, credential_from: "issuer"))

      assert {:error, :ended_by_its_starter} = Runs.close_run(scope, stale)

      after_close = Repo.get!(Run, stale.id)

      assert {after_close.state, after_close.closed_at, after_close.closed_by_id} ==
               {"running", nil, nil}

      refute Runs.closed?(scope.workspace.id, stale.run_id)
    end

    test "a run a session opened closes, from every state without an end, unless its credential came from an issuer",
         %{scope: scope} do
      for opened_by <- ["session", nil],
          credential_from <- ["none", nil],
          state <- Runs.closable_states() do
        run =
          run_fixture(scope, %{
            state: state,
            opened_by: opened_by,
            credential_from: credential_from
          })

        assert Runs.closable?(run)
        assert {:ok, %Run{state: "closed"}} = Runs.close_run(scope, run)
      end
    end
  end

  describe "closable?/1" do
    test "a run without an end that no gateway opened and whose credential came from no issuer",
         %{scope: scope} do
      for state <- ~w(succeeded ended failed timed_out closed),
          opened_by <- ["session", "gateway"] do
        refute Runs.closable?(run_fixture(scope, %{state: state, opened_by: opened_by}))
      end

      assert Runs.closable?(run_fixture(scope, %{state: "lost", opened_by: "session"}))
      refute Runs.closable?(run_fixture(scope, %{state: "lost", opened_by: "gateway"}))

      for credential_from <- ["none", nil] do
        assert Runs.closable?(
                 run_fixture(scope, %{
                   state: "lost",
                   opened_by: "session",
                   credential_from: credential_from
                 })
               )
      end

      refute Runs.closable?(
               run_fixture(scope, %{
                 state: "lost",
                 opened_by: "session",
                 credential_from: "issuer"
               })
             )

      refute Runs.closable?(
               run_fixture(scope, %{
                 state: "lost",
                 opened_by: "gateway",
                 credential_from: "issuer"
               })
             )
    end
  end

  describe "closed?/2" do
    test "the same subject in another workspace is another run", %{scope: scope, other: other} do
      run = run_fixture(scope)
      run_fixture(other, %{run_id: run.run_id})
      {:ok, _} = Runs.close_run(scope, run)

      assert Runs.closed?(scope.workspace.id, run.run_id)
      refute Runs.closed?(other.workspace.id, run.run_id)
    end

    test "an unknown or malformed subject is not closed", %{scope: scope} do
      refute Runs.closed?(scope.workspace.id, Ecto.UUID.generate())
      refute Runs.closed?(scope.workspace.id, "not-a-uuid")
      refute Runs.closed?(nil, nil)
    end
  end

  describe "last_heartbeats_by_key/1" do
    test "the workspace's keys that delivered a heartbeat, by id", %{scope: scope, other: other} do
      %{access_key: beating} = access_key_fixture(scope)
      %{access_key: silent} = access_key_fixture(scope)
      %{access_key: elsewhere} = access_key_fixture(other)
      at = ~U[2026-09-16 12:00:30.000000Z]

      Repo.update_all(from(k in AccessKey, where: k.id in ^[beating.id, elsewhere.id]),
        set: [last_heartbeat_at: at]
      )

      assert Runs.last_heartbeats_by_key(scope) == %{beating.id => at}
      refute Map.has_key?(Runs.last_heartbeats_by_key(scope), silent.id)
    end
  end
end
