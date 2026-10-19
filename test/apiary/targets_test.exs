defmodule Apiary.TargetsTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [run_fixture: 2]
  import Apiary.RunListFixtures

  alias Apiary.Policy
  alias Apiary.Targets

  @day 86_400

  # The moment the index and a target's page are read at, which the runs are placed back
  # from: the fourteen days end with its UTC day, which a run a minute before the clock
  # would miss just after midnight.
  @now ~U[2026-09-20 14:00:00.000000Z]

  defp repo(system, path), do: %{"forge" => system, "repository" => path}

  defp ended(scope, labels, state, opts) do
    exit =
      case state do
        "succeeded" -> %{"state" => "succeeded", "exit_code" => 0}
        "failed" -> %{"state" => "failed", "exit_code" => 1}
      end

    started_run(scope, labels, opts |> Keyword.put(:exit, exit) |> Keyword.put(:now, @now))
  end

  defp target(scope, system, path), do: Targets.get(scope, system, path)

  describe "pins" do
    test "a person's pins, in the order pinned, with whether the path is in another system" do
      %{scope: scope} = sign_up_fixture()
      started_run(scope, repo("github.example", "acme/shop"))
      started_run(scope, repo("gitlab.example", "acme/shop"))
      started_run(scope, repo("github.example", "acme/api"))

      api = target(scope, "github.example", "acme/api")
      shop = target(scope, "gitlab.example", "acme/shop")

      assert :ok = Targets.pin(scope, api)
      assert :ok = Targets.pin(scope, shop)
      # Pinning again changes nothing, the order included.
      assert :ok = Targets.pin(scope, api)

      assert [
               %{id: api_id, path: "acme/api", system: "github.example", shared: false},
               %{id: shop_id, path: "acme/shop", system: "gitlab.example", shared: true}
             ] = pins = Targets.list_pins(scope)

      assert {api_id, shop_id} == {api.id, shop.id}
      # Each with its public id, which addresses its page.
      assert Enum.map(pins, & &1.public_id) == [api.public_id, shop.public_id]
      assert Targets.pinned?(scope, api)
      assert Targets.pinned_ids(scope) == MapSet.new([api.id, shop.id])
      assert [%{id: ^api_id}] = Targets.list_pins(scope, 1)

      assert :ok = Targets.unpin(scope, api)
      assert :ok = Targets.unpin(scope, api)
      assert [%{id: ^shop_id}] = Targets.list_pins(scope)
      refute Targets.pinned?(scope, api)
    end

    test "a pin is the person's own: another member's pins are theirs" do
      %{scope: scope} = sign_up_fixture()
      %{scope: member} = member_fixture(scope, :member)
      started_run(scope, repo("github.example", "acme/shop"))
      shop = target(scope, "github.example", "acme/shop")

      :ok = Targets.pin(member, shop)
      assert Targets.list_pins(scope) == []
      assert [%{id: id}] = Targets.list_pins(member)
      assert id == shop.id
    end

    test "a target of another organisation is neither pinned nor listed" do
      %{scope: scope} = sign_up_fixture()
      %{scope: other} = sign_up_fixture()
      started_run(other, repo("github.example", "acme/shop"))
      theirs = target(other, "github.example", "acme/shop")
      :ok = Targets.pin(other, theirs)

      assert {:error, :not_found} = Targets.pin(scope, theirs)
      assert {:error, :not_found} = Targets.unpin(scope, theirs)
      assert Targets.list_pins(scope) == []
      assert Targets.pinned_ids(scope) == MapSet.new()
      refute Targets.pinned?(scope, theirs)
      assert Targets.get(scope, "github.example", "acme/shop") == nil
      assert Targets.get_by_id(scope, theirs.id) == nil
      assert [_] = Targets.list_pins(other)
    end

    test "a pin goes with its target" do
      %{scope: scope} = sign_up_fixture()
      started_run(scope, repo("github.example", "acme/shop"))
      shop = target(scope, "github.example", "acme/shop")
      :ok = Targets.pin(scope, shop)

      Repo.delete!(shop)
      assert Targets.list_pins(scope) == []
    end
  end

  describe "the index" do
    setup do
      %{scope: scope} = sign_up_fixture()

      ended(scope, repo("github.example", "acme/shop"), "succeeded", ago: 60)
      ended(scope, repo("github.example", "acme/shop"), "failed", ago: 3 * @day)

      ended(scope, repo("gitlab.example", "acme/shop"), "succeeded",
        ago: 40 * @day,
        egress: [%{"decision" => "denied", "outcome" => "refused", "host" => "x.example"}]
      )

      ended(scope, repo("github.example", "acme/api"), "succeeded",
        ago: 2 * @day,
        egress: [
          %{"decision" => "denied", "outcome" => "refused", "host" => "a.example"},
          %{"decision" => "denied", "outcome" => "refused", "host" => "b.example"}
        ]
      )

      ended(scope, repo("git.example.com", "web/blog"), "succeeded", ago: 100 * @day)

      %{scope: scope}
    end

    test "every target with its last run, runs a day, how they ended and its denials", %{
      scope: scope
    } do
      %{rows: rows, total: 4, page: 1, pages: 1} = Targets.page(scope, %{}, @now)

      # By last run, newest first.
      assert Enum.map(rows, &{&1.target.system, &1.target.path}) == [
               {"github.example", "acme/shop"},
               {"github.example", "acme/api"},
               {"gitlab.example", "acme/shop"},
               {"git.example.com", "web/blog"}
             ]

      [shop, api, mirror, blog] = rows
      assert shop.last.state == "completed"
      assert shop.runs == 2 and shop.ended_well == 1 and shop.ended_badly == 1
      assert length(shop.days) == 14 and Enum.sum(shop.days) == 2
      assert List.last(shop.days) == 1
      assert shop.shared and mirror.shared
      refute api.shared or blog.shared
      assert api.denied == 2
      # Outside the window: a last run, and nothing counted in it.
      assert mirror.runs == 0 and mirror.denied == 0 and mirror.last.state == "completed"
      assert Enum.sum(blog.days) == 0
    end

    test "the views, the search and its qualifiers", %{scope: scope} do
      paths = fn query ->
        scope
        |> Targets.page(query, @now)
        |> Map.fetch!(:rows)
        |> Enum.map(&"#{&1.target.system}/#{&1.target.path}")
      end

      assert Targets.view_counts(scope, @now) == %{all: 4, active: 2, never: 0}
      assert paths.(%{view: :active}) == ["github.example/acme/shop", "github.example/acme/api"]
      assert paths.(%{view: :never}) == []
      assert paths.(%{text: "SHOP"}) == ["github.example/acme/shop", "gitlab.example/acme/shop"]
      assert paths.(%{text: "gitlab.example/"}) == ["gitlab.example/acme/shop"]
      # The pattern's own characters are text.
      assert paths.(%{text: "%"}) == []
      assert paths.(%{systems: ["git.example.com"]}) == ["git.example.com/web/blog"]

      assert paths.(%{activity: :quiet_30}) == [
               "gitlab.example/acme/shop",
               "git.example.com/web/blog"
             ]

      assert paths.(%{activity: :quiet_90}) == ["git.example.com/web/blog"]

      assert Targets.systems(scope) == [
               {"github.example", 2},
               {"git.example.com", 1},
               {"gitlab.example", 1}
             ]
    end

    @tag needs: :security
    test "the policy's modes and the reader's pins", %{scope: scope} do
      api = target(scope, "github.example", "acme/api")
      blog = target(scope, "git.example.com", "web/blog")
      {:ok, _} = Policy.set_mode(scope, blog, "observe")
      :ok = Targets.pin(scope, api)

      paths = fn query ->
        scope |> Targets.page(query, @now) |> Map.fetch!(:rows) |> Enum.map(& &1.target.path)
      end

      assert paths.(%{modes: [:observes]}) == ["web/blog"]
      assert paths.(%{modes: [:enforces]}) == []
      assert length(paths.(%{modes: [:follows]})) == 3
      assert paths.(%{pinned: true}) == ["acme/api"]
    end

    test "the sorts, each ending on the path and the system", %{scope: scope} do
      order = fn sort ->
        scope
        |> Targets.page(%{sort: sort}, @now)
        |> Map.fetch!(:rows)
        |> Enum.map(&"#{&1.target.system}/#{&1.target.path}")
      end

      assert order.(:name) == [
               "github.example/acme/api",
               "github.example/acme/shop",
               "gitlab.example/acme/shop",
               "git.example.com/web/blog"
             ]

      assert hd(order.(:runs)) == "github.example/acme/shop"
      assert hd(order.(:denials)) == "github.example/acme/api"
    end

    test "pages of 50, and a page past the end is the last", %{scope: scope} do
      for n <- 1..48,
          do: started_run(scope, repo("github.example", "bulk/#{n}"), ago: 600 + n, now: @now)

      assert %{page: 1, pages: 2, total: 52, rows: rows} = Targets.page(scope, %{}, @now)
      assert length(rows) == 50
      assert %{page: 2, rows: [_, _]} = Targets.page(scope, %{page: 2}, @now)
      assert %{page: 2, rows: [_, _]} = Targets.page(scope, %{page: 9}, @now)
    end

    test "another organisation's targets are not in it" do
      %{scope: other} = sign_up_fixture()
      assert %{rows: [], total: 0} = Targets.page(other, %{})
      assert Targets.view_counts(other) == %{all: 0, active: 0, never: 0}
      assert Targets.systems(other) == []
    end
  end

  describe "a target's page" do
    test "every state counts in its family" do
      %{scope: scope} = sign_up_fixture()
      ended(scope, repo("github.example", "acme/shop"), "succeeded", ago: 60)
      shop = target(scope, "github.example", "acme/shop")
      at = DateTime.add(@now, -120, :second)

      for state <- ~w(pending running completed failed cancelled lost),
          do: run_fixture(scope, %{state: state, started_at: at, target_id: shop.id})

      # Cancelled is neither ended well nor ended badly, so a page's share leaves it out.
      assert Targets.summary(scope, shop, @now).window ==
               %{runs: 7, ended_well: 2, cancelled: 1, ended_badly: 2, denied: 0}

      assert %{rows: [row]} = Targets.page(scope, %{}, @now)
      assert %{runs: 7, ended_well: 2, cancelled: 1, ended_badly: 2} = row
    end

    test "its summary, runs, denials, machines, runtimes and the same path elsewhere" do
      %{scope: scope} = sign_up_fixture()

      first =
        ended(scope, repo("github.example", "acme/shop"), "succeeded",
          ago: 20 * @day,
          host: "ci-01"
        )

      ended(scope, repo("github.example", "acme/shop"), "failed",
        ago: 120,
        host: "ci-02",
        egress: [
          %{"decision" => "denied", "outcome" => "refused", "host" => "files.cdn.example"},
          %{
            "decision" => "denied",
            "outcome" => "refused",
            "host" => "files.cdn.example",
            "path" => "/x"
          }
        ]
      )

      last =
        ended(scope, repo("github.example", "acme/shop"), "succeeded", ago: 60, host: "ci-01")

      started_run(scope, repo("gitlab.example", "acme/shop"), now: @now)

      shop = target(scope, "github.example", "acme/shop")
      summary = Targets.summary(scope, shop, @now)

      assert summary.runs == 3
      assert summary.first.public_id == first.public_id
      assert summary.last.public_id == last.public_id
      assert summary.window == %{runs: 2, ended_well: 1, cancelled: 0, ended_badly: 1, denied: 2}
      assert List.last(summary.days) == 2

      assert [%{node_run_id: newest}, _, _] = Targets.recent_runs(scope, shop, 10)
      assert newest == last.node_run_id
      assert [_] = Targets.recent_runs(scope, shop, 1)

      since = DateTime.add(@now, -14 * @day, :second)

      # A destination is its host, port and path, as Network access counts it.
      assert %{rows: rows, destinations: 2, attempts: 2} =
               Targets.denied_destinations(scope, shop, since)

      assert rows |> Enum.map(&{&1.host, &1.port, &1.path, &1.attempts, &1.runs}) |> Enum.sort() ==
               [{"files.cdn.example", 443, "", 1, 1}, {"files.cdn.example", 443, "/x", 1, 1}]

      assert Targets.machines(scope, shop) == [{"ci-01", 2}, {"ci-02", 1}]
      assert Targets.runtimes(scope, shop) == [{"claude 2.1.0", 3}]
      assert [{%{system: "gitlab.example"}, 1}] = Targets.elsewhere(scope, shop)
      assert Targets.count_runs(scope, shop) == 3
      assert Targets.shared?(scope, "acme/shop")
      refute Targets.shared?(scope, "acme/api")
    end
  end

  describe "days in the reader's zone" do
    test "the index's and a target's fourteen days end with the reader's today" do
      %{scope: scope} = sign_up_fixture()
      # @now is 14:00 UTC on 20 September 2026, 02:00 on the 21st in Auckland (NZST, UTC+12),
      # whose day turned at 12:00 UTC: one run before it, one after.
      started_run(scope, repo("github.example", "acme/shop"), now: @now, ago: 2 * 3600 + 60)
      started_run(scope, repo("github.example", "acme/shop"), now: @now, ago: 2 * 3600 - 60)
      shop = target(scope, "github.example", "acme/shop")

      days = fn scope ->
        %{rows: [row]} = Targets.page(scope, %{}, @now)
        summary = Targets.summary(scope, shop, @now)
        assert row.days == summary.days
        Enum.take(row.days, -2)
      end

      assert days.(scope) == [0, 2]
      assert days.(%{scope | user: %{scope.user | time_zone: "Pacific/Auckland"}}) == [1, 1]
    end
  end

  defp further_errors({:error, %Ecto.Changeset{} = changeset}),
    do: errors_on(changeset).further_repositories

  defp saved(scope, target),
    do: Targets.further_repositories(target(scope, target.system, target.path))

  defp entries_of(target) do
    Apiary.Repo.all(
      from e in Apiary.Audit.Entry,
        where: e.action == "target.set_further_repositories" and e.subject_id == ^target.id,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  describe "what a target's runs also read" do
    @describetag needs: :factory

    setup do
      %{scope: scope} = sign_up_fixture()

      :ok =
        Apiary.Runs.Target.insert_new(scope.organisation.id, scope.workspace.id, [
          %{system: "code.example.com", path: "acme/shop"}
        ])

      %{scope: scope, shop: target(scope, "code.example.com", "acme/shop")}
    end

    test "none until somebody chooses them", %{shop: shop} do
      assert Targets.further_repositories(shop) == []
    end

    test "a list saved is read back whole, in the order given, with its audit entry",
         %{scope: scope, shop: shop} do
      assert {:ok, saved} =
               Targets.set_further_repositories(scope, shop, "acme/zeta\nacme/alpha\nacme/docs")

      assert Targets.further_repositories(saved) == ["acme/zeta", "acme/alpha", "acme/docs"]
      assert saved(scope, shop) == ["acme/zeta", "acme/alpha", "acme/docs"]

      assert [entry] = entries_of(shop)
      assert entry.before == %{"further_repositories" => []}
      assert entry.after == %{"further_repositories" => ["acme/zeta", "acme/alpha", "acme/docs"]}

      # A list replaces the whole list; the same list again writes nothing.
      assert {:ok, _saved} = Targets.set_further_repositories(scope, saved, ["acme/docs"])
      assert saved(scope, shop) == ["acme/docs"]
      assert {:ok, _saved} = Targets.set_further_repositories(scope, saved, "acme/docs")
      assert length(entries_of(shop)) == 2

      # An empty text clears it.
      assert {:ok, cleared} = Targets.set_further_repositories(scope, shop, "")
      assert Targets.further_repositories(cleared) == []
      assert saved(scope, shop) == []
    end

    test "white space around a line and blank lines are dropped", %{scope: scope, shop: shop} do
      assert {:ok, _saved} =
               Targets.set_further_repositories(
                 scope,
                 shop,
                 "  acme/docs  \r\n\n\t\nacme/api\t\n   \n"
               )

      assert saved(scope, shop) == ["acme/docs", "acme/api"]
    end

    test "each broken rule is refused with the first one, naming its line, and nothing is written",
         %{scope: scope, shop: shop} do
      {:ok, shop} = Targets.set_further_repositories(scope, shop, "acme/docs")
      set = &further_errors(Targets.set_further_repositories(scope, shop, &1))

      for text <- [
            "acme",
            "acme/docs/extra",
            "acme/",
            "/docs",
            "acme/.",
            "acme/..",
            "acme/.git",
            "acme/.GIT",
            ".Git/docs",
            "acme/do cs",
            "acme/dös",
            "acme\\docs",
            "acme/-rf"
          ] do
        assert set.("acme/api\n" <> text) == ["Line 2 is not a path such as acme/docs."],
               inspect(text)
      end

      assert set.("acme/" <> String.duplicate("a", 196)) ==
               ["Line 1 is longer than 200 characters."]

      assert set.("other/docs") ==
               ["Line 1 is not a target of acme; runs of acme/shop read only targets of acme."]

      assert set.("ACME/Shop") == ["Line 1 is acme/shop itself."]
      # A blank line counts: the line is the one the person sees.
      assert set.("acme/docs\n\nacme/api\nACME/DOCS") == ["Line 4 repeats line 1."]
      # The first broken rule only.
      assert set.("acme/api\nother/docs\nnot a path") ==
               ["Line 2 is not a target of acme; runs of acme/shop read only targets of acme."]

      assert saved(scope, shop) == ["acme/docs"]
      assert length(entries_of(shop)) == 1
    end

    test "the owner is compared without case", %{scope: scope, shop: shop} do
      assert {:ok, _saved} = Targets.set_further_repositories(scope, shop, "ACME/Docs\nAcme/api")
      assert saved(scope, shop) == ["ACME/Docs", "Acme/api"]
    end

    test "a path is at most 200 characters: 200 is saved, 201 refused",
         %{scope: scope, shop: shop} do
      at_most = "acme/" <> String.duplicate("a", 195)
      assert byte_size(at_most) == 200
      assert {:ok, _saved} = Targets.set_further_repositories(scope, shop, at_most)

      assert further_errors(Targets.set_further_repositories(scope, shop, at_most <> "a")) ==
               ["Line 1 is longer than 200 characters."]

      assert saved(scope, shop) == [at_most]
    end

    test "the target and the list, joined with commas, are at most 256: 256 is saved, 257 refused",
         %{scope: scope, shop: shop} do
      first = "acme/" <> String.duplicate("a", 195)
      second = "acme/" <> String.duplicate("b", 40)
      assert byte_size(Enum.join(["acme/shop", first, second], ",")) == 256

      assert {:ok, _saved} = Targets.set_further_repositories(scope, shop, [first, second])

      assert further_errors(Targets.set_further_repositories(scope, shop, [first, second <> "b"])) ==
               ["Together with acme/shop, these come to 257 characters; the most is 256."]

      assert saved(scope, shop) == [first, second]
    end

    test "owners and admins choose them; a member is refused", %{scope: owner, shop: shop} do
      admin = member_fixture(owner, :admin).scope
      member = member_fixture(owner, :member).scope

      assert {:ok, _saved} = Targets.set_further_repositories(owner, shop, "acme/docs")
      assert {:ok, _saved} = Targets.set_further_repositories(admin, shop, "acme/api")

      assert Targets.set_further_repositories(member, shop, "acme/web") == {:error, :forbidden}
      # Refused before the list is read.
      assert Targets.set_further_repositories(member, shop, "not a path") ==
               {:error, :forbidden}

      assert saved(owner, shop) == ["acme/api"]
    end

    test "another organisation's target is not reachable", %{scope: scope, shop: shop} do
      %{scope: other} = sign_up_fixture()

      assert Targets.set_further_repositories(other, shop, "acme/docs") == {:error, :not_found}
      assert saved(scope, shop) == []
      assert entries_of(shop) == []
    end

    test "not found where the reader is not shown the feature", %{scope: scope, shop: shop} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([:factory])

      assert Targets.set_further_repositories(scope, shop, "acme/docs") == {:error, :not_found}
      assert saved(scope, shop) == []
    end
  end
end
