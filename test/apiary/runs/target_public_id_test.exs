defmodule Apiary.Runs.TargetPublicIdTest do
  # A target's public id, `tg_` and 16 characters: set by the projector when it creates the
  # target, or by the column's default, `target_public_id()`, for a row written without
  # one. Its page is addressed by it (`ApiaryWeb.TargetLive.Show`).
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias Apiary.{PublicId, Repo, Targets}
  alias Apiary.Runs.Target

  @format ~r/\Atg_[0-9a-hjkmnp-tv-z]{16}\z/

  defp repo(system, path), do: %{"forge" => system, "repository" => path}

  defp raw_insert!(scope, path) do
    Repo.insert!(%Target{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      system: "github.example",
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  test "a target a run names has an id of the shape, and two targets have two", %{scope: scope} do
    started_run(scope, repo("github.example", "acme/shop"))
    started_run(scope, repo("gitlab.example", "acme/shop"))

    one = Targets.get(scope, "github.example", "acme/shop")
    other = Targets.get(scope, "gitlab.example", "acme/shop")

    for target <- [one, other] do
      assert target.public_id =~ @format
      assert PublicId.valid?("tg", target.public_id)
    end

    assert one.public_id != other.public_id
  end

  test "a run that names a target already seen keeps the target's row and its id", %{
    scope: scope
  } do
    started_run(scope, repo("github.example", "acme/shop"))
    target = Targets.get(scope, "github.example", "acme/shop")

    # An id the projector would never make: one it overwrote would show.
    kept = "tg_0000000000000000"
    Repo.update_all(from(t in Target, where: t.id == ^target.id), set: [public_id: kept])

    run = started_run(scope, repo("github.example", "acme/shop"))

    assert Repo.get!(Apiary.Runs.Run, run.id).target_id == target.id
    assert Repo.get!(Target, target.id).public_id == kept

    assert Repo.aggregate(from(t in Target, where: t.workspace_id == ^scope.workspace.id), :count) ==
             1
  end

  test "a row written without an id gets the column's default, which Ecto reads back", %{
    scope: scope
  } do
    one = raw_insert!(scope, "acme/one")
    other = raw_insert!(scope, "acme/two")

    assert one.public_id =~ @format
    assert other.public_id =~ @format
    assert one.public_id != other.public_id
    assert Repo.get!(Target, one.id).public_id == one.public_id
  end

  test "the database refuses an id of another shape, and a second target with the same id", %{
    scope: scope
  } do
    target = raw_insert!(scope, "acme/shop")

    for bad <- ~w(tg_000000000000000 tg_000000000000000i ws_0000000000000000 TG_0000000000000000) do
      assert_raise Postgrex.Error, ~r/targets_public_id_format/, fn ->
        Repo.transaction(fn ->
          Repo.update_all(from(t in Target, where: t.id == ^target.id), set: [public_id: bad])
        end)
      end
    end

    other = raw_insert!(scope, "acme/other")

    assert_raise Postgrex.Error, ~r/targets_public_id_index/, fn ->
      Repo.transaction(fn ->
        Repo.update_all(from(t in Target, where: t.id == ^other.id),
          set: [public_id: target.public_id]
        )
      end)
    end
  end

  test "target_public_id() runs with its search_path set to pg_catalog" do
    assert %{rows: [[["search_path=pg_catalog"]]]} =
             Repo.query!("SELECT proconfig FROM pg_proc WHERE proname = 'target_public_id'")
  end

  test "target_public_id() makes ids of the shape, all different, over many calls" do
    %{rows: rows} = Repo.query!("SELECT target_public_id() FROM generate_series(1, 5000)")
    ids = List.flatten(rows)

    assert length(ids) == 5000
    assert Enum.all?(ids, &(&1 =~ @format))
    assert Enum.all?(ids, &PublicId.valid?("tg", &1))
    assert length(Enum.uniq(ids)) == 5000

    # Every character of the alphabet turns up, in the first place and the last alike:
    # every five bits are read.
    for position <- [3, 18] do
      seen = ids |> Enum.map(&String.at(&1, position)) |> Enum.uniq() |> length()
      assert seen == 32, "position #{position}"
    end
  end

  describe "get_by_public_id/2" do
    test "finds the scope's workspace's target by its id, and nothing else", %{scope: scope} do
      started_run(scope, repo("github.example", "acme/shop"))
      target = Targets.get(scope, "github.example", "acme/shop")

      assert Targets.get_by_public_id(scope, target.public_id).id == target.id

      other = scope_fixture()
      started_run(other, repo("github.example", "acme/shop"))
      theirs = Targets.get(other, "github.example", "acme/shop")

      # Another workspace's target, by its id: not this workspace's.
      assert Targets.get_by_public_id(scope, theirs.public_id) == nil
      assert Targets.get_by_public_id(other, theirs.public_id).id == theirs.id

      for missing <- [
            "tg_0000000000000000",
            String.upcase(target.public_id),
            "nd_" <> binary_part(target.public_id, 3, 16),
            target.id,
            "acme/shop",
            "",
            nil
          ] do
        assert Targets.get_by_public_id(scope, missing) == nil, inspect(missing)
      end
    end
  end
end
