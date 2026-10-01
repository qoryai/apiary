defmodule ApiaryWeb.PolicyLive.RuleListTest do
  use ExUnit.Case, async: true

  alias ApiaryWeb.PolicyLive.RuleList

  @own %{key: "repo", label: "This target", rank: 0}
  @main %{key: "main", label: "Main", rank: 2}

  defp row(host, extra \\ []) do
    Map.merge(
      %{
        id: host,
        action: "allow",
        host: host,
        paths: nil,
        locked: false,
        by: "dana",
        at: ~U[2026-09-01 10:00:00.000000Z],
        source: @main
      },
      Map.new(extra)
    )
  end

  defp rows do
    [
      row("hooks.chat.example", action: "deny", locked: true, by: "dana"),
      row("telemetry.example", action: "deny", by: "priya"),
      row("api.example", paths: ["/v1/*"], at: ~U[2026-09-20 10:00:00.000000Z]),
      row("github.example", by: "sam"),
      row("*.github.example"),
      row("registry.example", by: nil)
    ]
  end

  defp hosts(listing), do: Enum.map(listing.rows, & &1.host)

  describe "the URL" do
    test "is read, and written back without what it does not know" do
      query = RuleList.parse(%{"view" => "allowed", "q" => "seen:no golang", "sort" => "host"})

      assert %RuleList{view: :allow, tokens: [seen: :no], text: "golang", sort: :host, page: 1} =
               query

      assert RuleList.to_params(query) == %{
               "view" => "allowed",
               "q" => "seen:no golang",
               "sort" => "host"
             }

      assert RuleList.parse(%{}) == %RuleList{}
      assert RuleList.to_params(%RuleList{}) == %{}

      assert RuleList.parse(%{"view" => "bogus", "sort" => ["x"], "q" => ["y"], "page" => "0"}) ==
               %RuleList{}

      assert RuleList.parse(%{"page" => "3"}).page == 3
      assert RuleList.parse(%{"page" => "99999999"}).page == 1
      assert RuleList.parse(%{"page" => "9999"}).page == 1_000
    end

    test "canonical? is whether the parameters are what it would write" do
      assert RuleList.canonical?(%{"view" => "denied", "rule" => "x"})
      refute RuleList.canonical?(%{"view" => "bogus"})
      refute RuleList.canonical?(%{"page" => "1"})
      refute RuleList.canonical?(%{"q" => "golang  seen:no"})
      assert RuleList.canonical?(%{"q" => "seen:no golang"})
    end

    test "a search is its qualifiers, one of a kind, then its text" do
      assert RuleList.parse_search("seen:yes golang seen:no by:Dana source:main paths:held x") ==
               {[seen: :no, by: "Dana", source: "main", paths: :held], "golang x"}

      assert RuleList.parse_search("seen:maybe by: paths:") == {[], "seen:maybe by: paths:"}
      assert RuleList.parse_search(nil) == {[], ""}
      assert RuleList.pending("gol seen:n by:") == "gol"
      assert RuleList.token_text({:by, "dana"}) == "by:dana"
    end

    test "toggle adds a token, replaces one of its kind and takes it away, on the first page" do
      query = %RuleList{page: 3}
      on = RuleList.toggle(query, {:seen, :no})
      assert on.tokens == [seen: :no] and on.page == 1
      assert RuleList.toggle(on, {:seen, :yes}).tokens == [seen: :yes]
      assert RuleList.toggle(on, {:seen, :no}).tokens == []

      assert RuleList.typed(on, [paths: :held], "x") == %RuleList{
               tokens: [seen: :no, paths: :held],
               text: "x"
             }

      assert RuleList.clear(%{on | text: "x", sort: :host}) == %RuleList{sort: :host}
      assert RuleList.narrowed?(on) and not RuleList.narrowed?(%RuleList{view: :deny})
    end
  end

  describe "the list" do
    test "its own order: locked, deny, allow, each by host read from the right" do
      listing = RuleList.list(rows(), %RuleList{}, :unavailable)

      assert hosts(listing) == [
               "hooks.chat.example",
               "telemetry.example",
               "api.example",
               "github.example",
               "*.github.example",
               "registry.example"
             ]

      assert listing.counts == %{all: 6, allow: 4, deny: 2, locked: 1}
      assert %{total: 6, match: nil, page: 1, pages: 1, first: 1, last: 6} = listing
      refute listing.loading or listing.unseen
    end

    test "a source ranks before the rest: a target's own first" do
      rows = [row("zzz.example", source: @own) | rows()]
      assert hd(hosts(RuleList.list(rows, %RuleList{}, :unavailable))) == "zzz.example"
      assert hd(hosts(RuleList.list(rows, %RuleList{sort: :host}, :unavailable))) == "api.example"
    end

    test "the views and the tokens narrow it, and the text is found in the host" do
      list = &RuleList.list(rows(), &1, :unavailable)
      assert hosts(list.(%RuleList{view: :deny})) == ["hooks.chat.example", "telemetry.example"]
      assert hosts(list.(%RuleList{view: :locked})) == ["hooks.chat.example"]
      assert list.(%RuleList{view: :locked}).match == nil
      assert hosts(list.(%RuleList{text: "GitHub"})) == ["github.example", "*.github.example"]
      assert list.(%RuleList{text: "GitHub"}).match == 2
      assert hosts(list.(%RuleList{tokens: [paths: :held]})) == ["api.example"]
      assert length(list.(%RuleList{tokens: [paths: :every]}).rows) == 5
      assert hosts(list.(%RuleList{tokens: [by: "SAM"]})) == ["github.example"]
      assert hosts(list.(%RuleList{tokens: [source: "repo"]})) == []

      assert hosts(list.(%RuleList{view: :allow, tokens: [by: "dana"], text: "api"})) == [
               "api.example"
             ]
    end

    test "seen: and Most used wait for the use, and say so when it could not be counted" do
      activity = %{
        "api.example" => %{allowed: 3, denied: 0},
        "telemetry.example" => %{allowed: 0, denied: 2}
      }

      assert %{loading: true, rows: [], counts: %{all: 6}} =
               RuleList.list(rows(), %RuleList{tokens: [seen: :no]}, :loading)

      assert RuleList.list(rows(), %RuleList{sort: :used}, :loading).loading
      refute RuleList.list(rows(), %RuleList{sort: :host}, :loading).loading

      assert hosts(RuleList.list(rows(), %RuleList{tokens: [seen: :yes]}, activity)) ==
               ["telemetry.example", "api.example"]

      assert length(RuleList.list(rows(), %RuleList{tokens: [seen: :no]}, activity).rows) == 4

      unseen = RuleList.list(rows(), %RuleList{tokens: [seen: :no]}, :unavailable)
      assert unseen.unseen and length(unseen.rows) == 6

      assert hosts(RuleList.list(rows(), %RuleList{sort: :used}, activity)) |> Enum.take(2) ==
               ["api.example", "telemetry.example"]
    end

    test "Host and Recently added are orders of their own" do
      assert hosts(RuleList.list(rows(), %RuleList{sort: :host}, :unavailable)) == [
               "api.example",
               "github.example",
               "*.github.example",
               "hooks.chat.example",
               "registry.example",
               "telemetry.example"
             ]

      assert hd(hosts(RuleList.list(rows(), %RuleList{sort: :recent}, :unavailable))) ==
               "api.example"
    end

    test "pages of 50, a page past the last showing the last" do
      rows = for n <- 1..120, do: row("h#{String.pad_leading("#{n}", 3, "0")}.example")

      first = RuleList.list(rows, %RuleList{}, :unavailable)
      assert %{page: 1, pages: 3, first: 1, last: 50, total: 120} = first
      assert length(first.rows) == 50

      last = RuleList.list(rows, %RuleList{page: 3}, :unavailable)
      assert %{page: 3, first: 101, last: 120} = last
      assert hd(hosts(last)) == "h101.example"

      assert RuleList.list(rows, %RuleList{page: 9}, :unavailable).page == 3

      assert %{first: 0, last: 0, pages: 1} =
               RuleList.list(rows, %RuleList{text: "nope"}, :unavailable)
    end

    test "landing is the page that holds a rule, in the query when it keeps the rule" do
      rows = for n <- 1..120, do: row("h#{String.pad_leading("#{n}", 3, "0")}.example")

      assert RuleList.landing(%RuleList{}, rows, :unavailable, "h077.example").page == 2
      assert RuleList.landing(%RuleList{page: 3}, rows, :unavailable, "h001.example").page == 1
      assert RuleList.landing(%RuleList{}, rows, :unavailable, nil) == %RuleList{}
      assert RuleList.landing(%RuleList{page: 3}, rows, :unavailable, "nope.example").page == 3

      # A filter that leaves the rule out gives way to every rule, in the query's order.
      narrowed = %RuleList{view: :deny, tokens: [by: "x"], sort: :host}
      landed = RuleList.landing(narrowed, rows, :unavailable, "h120.example")
      assert landed == %RuleList{sort: :host, page: 3}

      # Nothing is told while the use the query needs is still being counted.
      waiting = %RuleList{tokens: [seen: :no]}
      assert RuleList.landing(waiting, rows, :loading, "h077.example") == waiting
    end
  end

  describe "the Filter menu" do
    test "its sections count every row: Source where there is more than one, Paths, Seen, Added by" do
      activity = %{"api.example" => %{allowed: 3, denied: 0}}
      sections = RuleList.sections([row("own.example", source: @own) | rows()], activity)
      assert Enum.map(sections, & &1.key) == ~w(source paths seen by)

      [source, paths, seen, by] = sections

      assert source.items == [
               %{token: {:source, "repo"}, label: "This target", count: 1},
               %{token: {:source, "main"}, label: "Main", count: 6}
             ]

      assert Enum.map(paths.items, &{&1.token, &1.count}) == [
               {{:paths, :held}, 1},
               {{:paths, :every}, 6}
             ]

      assert Enum.map(seen.items, &{&1.token, &1.count}) == [
               {{:seen, :yes}, 1},
               {{:seen, :no}, 6}
             ]

      assert Enum.map(by.items, &{&1.token, &1.label, &1.count}) == [
               {{:by, "dana"}, "dana", 4},
               {{:by, "priya"}, "priya", 1},
               {{:by, "sam"}, "sam", 1}
             ]
    end

    test "one source is no section, and the use not counted is none either" do
      assert Enum.map(RuleList.sections(rows(), :unavailable), & &1.key) == ~w(paths by)
      assert Enum.map(RuleList.sections(rows(), :loading), & &1.key) == ~w(paths by)

      assert Enum.map(
               RuleList.sections([row("a.example", by: "Former member")], :unavailable),
               & &1.key
             ) == ~w(paths)
    end
  end
end
