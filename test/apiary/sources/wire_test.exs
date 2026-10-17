defmodule Apiary.Sources.WireTest do
  # The bodies an adapter posts with the items of a collection and the comments of an item,
  # read as the integration contract has them: every fixture of `source-items/` and
  # `source-item-comments/` vendored from the commit in `.integration-contract-ref`
  # accepted and read as written, every matching one of `invalid/` refused, and each
  # member held to its bound, at it and one past it.
  use ExUnit.Case, async: true

  alias Apiary.Sources.Wire

  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)

  defp fixture(path), do: @fixtures |> Path.join(path) |> File.read!()
  defp json(path), do: path |> fixture() |> Jason.decode!()

  defp fixtures(pattern),
    do:
      @fixtures
      |> Path.join(pattern)
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, @fixtures))

  defp time(value) do
    {:ok, time, 0} = DateTime.from_iso8601(value)
    time
  end

  # What a fixture reads as: its members, with atom keys and its times read.
  defp expected_items(body) do
    %{
      time: time(body["time"]),
      collection_ref: body["collection_ref"],
      items: Enum.map(body["items"], &expected_item/1),
      listing:
        body["listing"] &&
          %{
            id: body["listing"]["id"],
            part: body["listing"]["part"],
            started_at: time(body["listing"]["started_at"]),
            complete: body["listing"]["complete"]
          }
    }
  end

  defp expected_item(item) do
    %{
      ref: item["ref"],
      url: item["url"],
      key: item["key"],
      type: item["type"],
      title: item["title"],
      body: item["body"],
      body_format: item["body_format"],
      filed_by: %{name: item["filed_by"]["name"], kind: item["filed_by"]["kind"]},
      labels: item["labels"],
      state: item["state"],
      state_reason: item["state_reason"],
      comment_count: item["comment_count"],
      created_at: time(item["created_at"]),
      updated_at: time(item["updated_at"]),
      target: item["target"] && %{system: item["target"]["system"], path: item["target"]["path"]},
      truncated: Map.get(item, "truncated", [])
    }
  end

  defp expected_comments(body) do
    %{
      time: time(body["time"]),
      item_ref: body["item_ref"],
      comments: Enum.map(body["comments"], &expected_comment/1),
      complete: body["complete"] && %{since: time(body["complete"]["since"])}
    }
  end

  defp expected_comment(comment) do
    %{
      ref: comment["ref"],
      url: comment["url"],
      author: %{name: comment["author"]["name"], kind: comment["author"]["kind"]},
      body: comment["body"],
      body_format: comment["body_format"],
      created_at: time(comment["created_at"]),
      updated_at: time(comment["updated_at"]),
      deleted: Map.get(comment, "deleted", false),
      truncated: Map.get(comment, "truncated", [])
    }
  end

  # An event of one item, and a complete set of one comment, taken from the fixtures.
  defp event, do: json("source-items/acme-tracker-event-key.json")
  defp item, do: hd(event()["items"])
  defp event_of(item), do: Map.put(event(), "items", [item])
  defp listing_part, do: json("source-items/acme-tracker-listing-1-part-1.json")

  defp set, do: json("source-item-comments/acme-tracker-complete.json")
  defp comment, do: hd(set()["comments"])
  defp set_of(comment), do: Map.put(set(), "comments", [comment])
  defp without_complete(body), do: Map.delete(body, "complete")

  defp item_ok?(item), do: match?({:ok, _}, Wire.items(event_of(item)))
  defp comment_ok?(comment), do: match?({:ok, _}, Wire.comments(set_of(comment)))

  describe "the contract's fixtures" do
    test "every body of source-items/ is accepted and read as written, raw or decoded" do
      paths = fixtures("source-items/*.json")
      assert length(paths) == 15

      for name <- ~w(url-empty-port url-port-leading-zeros url-ip-literal),
          do: assert("source-items/acme-tracker-event-#{name}.json" in paths)

      for path <- paths do
        expected = expected_items(json(path))
        assert Wire.items(fixture(path)) == {:ok, expected}, path
        assert Wire.items(json(path)) == {:ok, expected}, path
      end
    end

    test "every body of source-item-comments/ is accepted and read as written, raw or decoded" do
      paths = fixtures("source-item-comments/*.json")
      assert length(paths) == 4

      for path <- paths do
        expected = expected_comments(json(path))
        assert Wire.comments(fixture(path)) == {:ok, expected}, path
        assert Wire.comments(json(path)) == {:ok, expected}, path
      end
    end

    test "what the fixtures carry is read: a key, a listing, a target, a cut, a deletion" do
      assert {:ok, %{listing: nil, items: [%{key: "#1231", type: nil, target: nil}]}} =
               Wire.items(fixture("source-items/acme-tracker-event-key.json"))

      assert {:ok,
              %{
                time: ~U[2026-10-15 11:00:05Z],
                collection_ref: "TRK",
                items: [
                  %{ref: "TRK-1", labels: ["checkout", "bug"]},
                  %{ref: "TRK-2", type: "task"}
                ],
                listing: %{
                  id: "items-1",
                  part: 1,
                  started_at: ~U[2026-10-15 11:00:00Z],
                  complete: false
                }
              }} = Wire.items(fixture("source-items/acme-tracker-listing-1-part-1.json"))

      assert {:ok, %{items: [], listing: %{part: 1, complete: true}}} =
               Wire.items(fixture("source-items/acme-tracker-listing-empty.json"))

      assert {:ok, %{items: [%{state: "closed", state_reason: "Fixed"}]}} =
               Wire.items(fixture("source-items/acme-tracker-listing-3-partial.json"))

      assert {:ok, %{items: [%{truncated: ["labels"], labels: labels}]}} =
               Wire.items(fixture("source-items/acme-tracker-event-labels-left-out.json"))

      assert length(labels) == 100

      assert {:ok, %{items: [%{type: "issue", target: %{system: _, path: "acme/shop"}}]}} =
               Wire.items(fixture("source-items/code-host-event.json"))

      assert {:ok, %{comments: [], complete: %{since: ~U[2026-10-15 11:59:55Z]}}} =
               Wire.comments(fixture("source-item-comments/acme-tracker-complete-empty.json"))

      assert {:ok, %{complete: nil, comments: [%{deleted: true, body: ""}]}} =
               Wire.comments(fixture("source-item-comments/code-host-deleted.json"))

      assert {:ok, %{comments: [%{truncated: ["body"], body: body}]}} =
               Wire.comments(fixture("source-item-comments/acme-tracker-truncated.json"))

      assert length(String.codepoints(body)) == 65_536

      assert {:ok, %{comments: [%{author: %{kind: "person"}}, %{author: %{kind: "automation"}}]}} =
               Wire.comments(fixture("source-item-comments/acme-tracker-complete.json"))
    end

    test "the body of the signed POST is read as the event it is" do
      signed = json("signed/post-source-items.json")
      assert signed["target"] == "/v1/source-items"

      assert Wire.items(signed["body"]) ==
               {:ok, expected_items(Jason.decode!(signed["body"]))}
    end

    test "every invalid body of items and of comments is refused" do
      items = fixtures("invalid/source-items-*.json")
      comments = fixtures("invalid/source-item-comments-*.json")
      assert length(items) == 22
      assert length(comments) == 2

      for name <- ~w(comment-count-above-maximum title-nul created-at-leap-second
                     created-at-hour-24 created-at-minute-60 url-user-information
                     url-bad-percent-escape url-port-0 url-port-65536),
          do: assert("invalid/source-items-#{name}.json" in items)

      for path <- items do
        assert Wire.items(fixture(path)) == :error, path
        assert Wire.items(json(path)) == :error, path
      end

      for path <- comments do
        assert Wire.comments(fixture(path)) == :error, path
        assert Wire.comments(json(path)) == :error, path
      end
    end
  end

  describe "the body" do
    test "anything but a JSON object, or one with a member twice, is refused" do
      for body <- ["", "[]", "null", "1", ~s("x"), "{", nil, [], 1] do
        assert Wire.items(body) == :error
        assert Wire.comments(body) == :error
      end

      twice =
        String.replace(
          fixture("source-items/acme-tracker-event-key.json"),
          ~s("key"),
          ~s("ref": "x", "key"),
          global: false
        )

      assert Wire.items(twice) == :error

      twice = ~s({"version":1,) <> String.slice(Jason.encode!(set()), 1..-1//1)
      assert Wire.comments(twice) == :error
    end

    test "version is the integer 1" do
      for version <- [1.0, "1", 2, 0, nil] do
        assert Wire.items(Map.put(event(), "version", version)) == :error
        assert Wire.comments(Map.put(set(), "version", version)) == :error
      end

      raw = Jason.encode!(Map.put(event(), "version", 1))
      assert Wire.items(String.replace(raw, ~s("version":1), ~s("version":1.0))) == :error
    end

    test "a member the schema does not define is refused, at every level" do
      assert Wire.items(Map.put(event(), "source", "x")) == :error
      assert Wire.items(event_of(Map.put(item(), "number", 1))) == :error

      assert Wire.items(event_of(put_in(item(), ["filed_by", "email"], "a@example.com"))) ==
               :error

      assert Wire.items(
               event_of(
                 Map.put(item(), "target", %{"system" => "a.example", "path" => "p", "x" => 1})
               )
             ) == :error

      assert Wire.items(put_in(listing_part(), ["listing", "x"], 1)) == :error
      assert Wire.comments(Map.put(set(), "x", 1)) == :error
      assert Wire.comments(put_in(set(), ["complete", "until"], "2026-10-15T12:00:00Z")) == :error
      assert Wire.comments(set_of(Map.put(comment(), "x", 1))) == :error
      assert Wire.comments(set_of(put_in(comment(), ["author", "x"], 1))) == :error
    end

    test "every required member is required, at every level" do
      for key <- ~w(version time collection_ref items),
          do: assert(Wire.items(Map.delete(event(), key)) == :error, key)

      for key <-
            ~w(ref url title body body_format filed_by labels state state_reason comment_count created_at updated_at),
          do: assert(Wire.items(event_of(Map.delete(item(), key))) == :error, key)

      for key <- ~w(name kind),
          do:
            assert(
              Wire.items(event_of(Map.update!(item(), "filed_by", &Map.delete(&1, key)))) ==
                :error
            )

      for key <- ~w(id part started_at complete),
          do:
            assert(
              Wire.items(Map.update!(listing_part(), "listing", &Map.delete(&1, key))) == :error
            )

      for key <- ~w(version time item_ref comments),
          do: assert(Wire.comments(Map.delete(set(), key)) == :error, key)

      for key <- ~w(ref url author body body_format created_at updated_at),
          do: assert(Wire.comments(set_of(Map.delete(comment(), key))) == :error, key)

      assert Wire.comments(Map.put(set(), "complete", %{})) == :error
    end

    test "a member that may be left out is refused written as null, or of another type" do
      for key <- ~w(key type target truncated), value <- [nil, 1, [], %{}] do
        refute item_ok?(Map.put(item(), key, value)), "#{key} #{inspect(value)}"
      end

      for value <- [nil, 1, "x", []] do
        assert Wire.items(Map.put(event(), "listing", value)) == :error
        assert Wire.comments(Map.put(set(), "complete", value)) == :error
      end

      for value <- [nil, false, "true", 1] do
        refute comment_ok?(Map.put(comment(), "deleted", value)), inspect(value)
      end

      assert {:ok, %{comments: [%{deleted: true}]}} =
               Wire.comments(set_of(Map.put(comment(), "deleted", true)))

      assert {:ok, %{comments: [%{deleted: false}]}} = Wire.comments(set_of(comment()))
    end
  end

  describe "the counts" do
    test "an event names 1 to 100 items; a listing part 0 to 100" do
      items = for n <- 1..101, do: Map.put(item(), "ref", "TRK-#{n}")

      assert {:ok, %{items: [_]}} = Wire.items(event_of(item()))

      assert {:ok, %{items: hundred}} =
               Wire.items(Map.put(event(), "items", Enum.take(items, 100)))

      assert length(hundred) == 100
      assert Wire.items(Map.put(event(), "items", items)) == :error
      assert Wire.items(Map.put(event(), "items", [])) == :error

      assert {:ok, %{items: []}} = Wire.items(Map.put(listing_part(), "items", []))
      assert {:ok, _} = Wire.items(Map.put(listing_part(), "items", Enum.take(items, 100)))
      assert Wire.items(Map.put(listing_part(), "items", items)) == :error

      for value <- [nil, %{}, "x", 1] do
        assert Wire.items(Map.put(event(), "items", value)) == :error
      end
    end

    test "a body without complete names 1 to 100 comments; with it, 0 to 100" do
      comments = for n <- 1..101, do: Map.put(comment(), "ref", "C-#{n}")

      assert {:ok, %{comments: []}} = Wire.comments(Map.put(set(), "comments", []))
      assert {:ok, _} = Wire.comments(Map.put(set(), "comments", Enum.take(comments, 100)))
      assert Wire.comments(Map.put(set(), "comments", comments)) == :error

      assert {:ok, %{complete: nil}} = Wire.comments(without_complete(set_of(comment())))

      assert {:ok, %{comments: hundred}} =
               Wire.comments(
                 without_complete(Map.put(set(), "comments", Enum.take(comments, 100)))
               )

      assert length(hundred) == 100
      assert Wire.comments(without_complete(Map.put(set(), "comments", comments))) == :error
      assert Wire.comments(without_complete(Map.put(set(), "comments", []))) == :error

      for value <- [nil, %{}, "x", 1] do
        assert Wire.comments(Map.put(set(), "comments", value)) == :error
      end
    end

    test "labels are at most 100, each a string of 1 to 100 code points with no U+0000, none twice" do
      labels = for n <- 1..101, do: "label-#{n}"

      assert item_ok?(Map.put(item(), "labels", []))
      assert item_ok?(Map.put(item(), "labels", Enum.take(labels, 100)))
      refute item_ok?(Map.put(item(), "labels", labels))
      refute item_ok?(Map.put(item(), "labels", ["bug", "bug"]))
      refute item_ok?(Map.put(item(), "labels", ["bug", ""]))
      refute item_ok?(Map.put(item(), "labels", ["bug", 1]))
      refute item_ok?(Map.put(item(), "labels", ["bug", nil]))
      refute item_ok?(Map.put(item(), "labels", "bug"))
      refute item_ok?(Map.put(item(), "labels", nil))

      # One label at its greatest length in code points, of one, two or four bytes, and
      # one past it.
      for character <- ["a", "\u00e9", "\u{1F600}"] do
        at = String.duplicate(character, 100)

        assert {:ok, %{items: [%{labels: ["bug", ^at]}]}} =
                 Wire.items(event_of(Map.put(item(), "labels", ["bug", at])))

        refute item_ok?(Map.put(item(), "labels", ["bug", at <> character])), character
      end

      for label <- ["a\u0000b", <<0>>, <<0xFF, 0xFE>>, "a" <> <<0xC3>>] do
        refute item_ok?(Map.put(item(), "labels", ["bug", label])), inspect(label)
      end

      # Equal as code points only: the same letter composed and decomposed are two labels.
      assert item_ok?(Map.put(item(), "labels", ["café", "café"]))
      assert item_ok?(Map.put(item(), "labels", ["Bug", "bug"]))
    end

    test "truncated names at least one of the fields an adapter may cut, each once" do
      for fields <- [
            ["title"],
            ["body"],
            ["filed_by.name"],
            ["labels"],
            ["title", "body", "filed_by.name", "labels"]
          ] do
        assert {:ok, %{items: [%{truncated: ^fields}]}} =
                 Wire.items(event_of(Map.put(item(), "truncated", fields)))
      end

      for fields <- [
            [],
            ["labels", "labels"],
            ["state_reason"],
            ["ref"],
            ["key"],
            ["author.name"],
            ["Title"],
            [1],
            ["title", "body", "filed_by.name", "labels", "title"]
          ] do
        refute item_ok?(Map.put(item(), "truncated", fields)), inspect(fields)
      end

      for fields <- [["body"], ["author.name"], ["author.name", "body"]] do
        assert {:ok, %{comments: [%{truncated: ^fields}]}} =
                 Wire.comments(set_of(Map.put(comment(), "truncated", fields)))
      end

      for fields <- [
            [],
            ["body", "body"],
            ["title"],
            ["filed_by.name"],
            ["labels"],
            ["body", "author.name", "body"]
          ] do
        refute comment_ok?(Map.put(comment(), "truncated", fields)), inspect(fields)
      end
    end
  end

  describe "text" do
    # Each text member: where it is, and its least and greatest length in code points.
    @texts [
      {:body, ["collection_ref"], 1, 200},
      {:item, ["ref"], 1, 200},
      {:item, ["key"], 1, 64},
      {:item, ["title"], 1, 1024},
      {:item, ["body"], 0, 65_536},
      {:item, ["filed_by", "name"], 1, 100},
      {:item, ["state_reason"], 0, 64},
      {:item, ["target", "path"], 1, 200},
      {:listing, ["listing", "id"], 1, 200},
      {:comments, ["item_ref"], 1, 200},
      {:comment, ["ref"], 1, 200},
      {:comment, ["body"], 0, 65_536},
      {:comment, ["author", "name"], 1, 100}
    ]

    defp with_text(:body, path, value), do: Wire.items(put_in(event(), path, value))
    defp with_text(:listing, path, value), do: Wire.items(put_in(listing_part(), path, value))
    defp with_text(:comments, path, value), do: Wire.comments(put_in(set(), path, value))

    defp with_text(:item, path, value) do
      item = Map.put(item(), "target", %{"system" => "code.example", "path" => "a/b"})
      Wire.items(event_of(put_in(item, path, value)))
    end

    defp with_text(:comment, path, value),
      do: Wire.comments(set_of(put_in(comment(), path, value)))

    test "each is read at its greatest length in code points, of one byte or four, and refused one past it" do
      for {where, path, _min, max} <- @texts, character <- ["a", "\u{1F600}", "é"] do
        at = String.duplicate(character, max)
        assert {:ok, _} = with_text(where, path, at), "#{inspect(path)} #{character}"

        assert with_text(where, path, at <> character) == :error,
               "#{inspect(path)} #{character} past"
      end
    end

    test "a letter and its combining mark are two code points" do
      for {where, path, _min, max} <- @texts, rem(max, 2) == 0 do
        at = String.duplicate("é", div(max, 2))
        assert {:ok, _} = with_text(where, path, at), inspect(path)
        assert with_text(where, path, at <> "e") == :error, inspect(path)
      end
    end

    test "each is refused shorter than its least length" do
      for {where, path, min, _max} <- @texts do
        if min == 0 do
          assert {:ok, _} = with_text(where, path, ""), inspect(path)
        else
          assert with_text(where, path, "") == :error, inspect(path)
        end
      end
    end

    test "each is refused holding U+0000, not valid UTF-8, or not a string" do
      for {where, path, _min, _max} <- @texts,
          value <- ["a\u0000b", <<0>>, <<0xFF, 0xFE>>, "a" <> <<0xC3>>, 1, true, ["a"], %{}] do
        assert with_text(where, path, value) == :error, "#{inspect(path)} #{inspect(value)}"
      end
    end

    test "state_reason may be null; the others may not" do
      assert {:ok, %{items: [%{state_reason: nil}]}} = with_text(:item, ["state_reason"], nil)

      for {where, path, _min, _max} <- @texts, path != ["state_reason"] do
        assert with_text(where, path, nil) == :error, inspect(path)
      end
    end

    test "a key is kept as sent, never read" do
      for key <- ["#1231", "1231", "ACME-7", " x ", "<b>", "\u{1F600}"] do
        assert {:ok, %{items: [%{key: ^key}]}} = Wire.items(event_of(Map.put(item(), "key", key)))
      end

      assert {:ok, %{items: [%{key: nil}]}} = Wire.items(event_of(Map.delete(item(), "key")))
    end
  end

  describe "words, states, counts and URLs" do
    test "type is a lower-case letter, then lower-case letters and spaces, 40 in all" do
      for type <- [
            "a",
            "task",
            "bug report",
            "a" <> String.duplicate(" ", 39),
            String.duplicate("z", 40)
          ] do
        assert {:ok, %{items: [%{type: ^type}]}} =
                 Wire.items(event_of(Map.put(item(), "type", type)))
      end

      for type <- [
            "",
            " task",
            "Task",
            "task-1",
            "bug_report",
            "tâche",
            "task\n",
            "\ntask",
            String.duplicate("z", 41),
            String.duplicate("z", 100_000)
          ] do
        refute item_ok?(Map.put(item(), "type", type)), inspect(type)
      end
    end

    test "body_format is a lower-case letter, then lower-case letters, digits, - and _, 40 in all" do
      for format <- ["markdown", "text", "a", "x-y_z9", String.duplicate("m", 40)] do
        assert item_ok?(Map.put(item(), "body_format", format))
        assert comment_ok?(Map.put(comment(), "body_format", format))
      end

      for format <- [
            "",
            "Markdown",
            "9text",
            "-text",
            "mark down",
            "text\n",
            String.duplicate("m", 41),
            nil,
            1
          ] do
        refute item_ok?(Map.put(item(), "body_format", format)), inspect(format)
        refute comment_ok?(Map.put(comment(), "body_format", format)), inspect(format)
      end
    end

    test "state is open or closed; a person is a person or an automation" do
      assert item_ok?(Map.put(item(), "state", "closed"))

      for state <- ["Open", "done", "", nil, 1],
          do: refute(item_ok?(Map.put(item(), "state", state)))

      for kind <- ["person", "automation"] do
        assert item_ok?(put_in(item(), ["filed_by", "kind"], kind))
        assert comment_ok?(put_in(comment(), ["author", "kind"], kind))
      end

      for kind <- ["app", "bot", "Person", "", nil] do
        refute item_ok?(put_in(item(), ["filed_by", "kind"], kind))
        refute comment_ok?(put_in(comment(), ["author", "kind"], kind))
      end

      for value <- [nil, "Ada", []] do
        refute item_ok?(Map.put(item(), "filed_by", value))
        refute comment_ok?(Map.put(comment(), "author", value))
      end
    end

    test "comment_count is an integer from 0 to 2^53 - 1" do
      for count <- [0, 1, 4_000_000_000, 9_007_199_254_740_991] do
        assert {:ok, %{items: [%{comment_count: ^count}]}} =
                 Wire.items(event_of(Map.put(item(), "comment_count", count)))
      end

      for count <- [-1, 9_007_199_254_740_992, 9_223_372_036_854_775_808, 1.0, "1", nil, true] do
        refute item_ok?(Map.put(item(), "comment_count", count)), inspect(count)
      end

      raw = Jason.encode!(event_of(Map.put(item(), "comment_count", 2)))

      for written <- ["2.0", "2e0", "-0.0"] do
        assert Wire.items(
                 String.replace(raw, ~s("comment_count":2), ~s("comment_count":#{written}))
               ) ==
                 :error
      end
    end

    test "a URL is https, at most 2,048 characters" do
      base = "https://tracker.acme.example/"
      at = base <> String.duplicate("a", 2048 - byte_size(base))

      assert item_ok?(Map.put(item(), "url", at))
      assert comment_ok?(Map.put(comment(), "url", at))
      refute item_ok?(Map.put(item(), "url", at <> "a"))
      refute comment_ok?(Map.put(comment(), "url", at <> "a"))

      for url <- [
            "http://tracker.acme.example/TRK-1",
            "https://",
            "https:///x",
            "tracker.acme.example",
            "https://a b.example/",
            "https://user@tracker.acme.example/",
            "https://tracker.acme.example/TRK%2G1",
            "https://tracker.acme.example:0/TRK-1",
            "https://tracker.acme.example:65536/TRK-1",
            "",
            nil
          ] do
        refute item_ok?(Map.put(item(), "url", url)), inspect(url)
        refute comment_ok?(Map.put(comment(), "url", url)), inspect(url)
      end

      for url <- [
            "https://tracker.acme.example:/TRK-1",
            "https://tracker.acme.example:0443/TRK-1",
            "https://tracker.acme.example:65535/TRK-1",
            "https://[2001:db8::1]/TRK-1"
          ] do
        assert item_ok?(Map.put(item(), "url", url)), inspect(url)
        assert comment_ok?(Map.put(comment(), "url", url)), inspect(url)
      end
    end

    test "a target is a host name of up to 253 characters and a path" do
      at = String.duplicate("a", 253)

      assert {:ok, %{items: [%{target: %{system: ^at, path: "a/b"}}]}} =
               Wire.items(event_of(Map.put(item(), "target", %{"system" => at, "path" => "a/b"})))

      for system <- [
            "",
            String.duplicate("a", 254),
            "Code.example",
            "code_example",
            "code.example\n",
            nil
          ] do
        refute item_ok?(Map.put(item(), "target", %{"system" => system, "path" => "a/b"})),
               inspect(system)
      end

      refute item_ok?(Map.put(item(), "target", %{"system" => "code.example"}))
      refute item_ok?(Map.put(item(), "target", %{"path" => "a/b"}))
    end

    test "a listing part is numbered from 1, with a time and whether it completes" do
      assert {:ok, %{listing: %{part: 9}}} =
               Wire.items(put_in(listing_part(), ["listing", "part"], 9))

      # As for a listing of collections: its parts are kept until it completes.
      max = Apiary.Adapters.Wire.max_part()

      assert {:ok, %{listing: %{part: ^max}}} =
               Wire.items(put_in(listing_part(), ["listing", "part"], max))

      for part <- [0, -1, 1.0, "1", nil, max + 1],
          do: assert(Wire.items(put_in(listing_part(), ["listing", "part"], part)) == :error)

      for complete <- ["true", 1, nil],
          do:
            assert(
              Wire.items(put_in(listing_part(), ["listing", "complete"], complete)) == :error
            )
    end
  end

  describe "times" do
    # Each time member, set in a body that is otherwise accepted.
    defp with_time(:time, value), do: Wire.items(Map.put(event(), "time", value))

    defp with_time(:created_at, value),
      do: Wire.items(event_of(Map.put(item(), "created_at", value)))

    defp with_time(:updated_at, value),
      do: Wire.items(event_of(Map.put(item(), "updated_at", value)))

    defp with_time(:started_at, value),
      do: Wire.items(put_in(listing_part(), ["listing", "started_at"], value))

    defp with_time(:comments_time, value), do: Wire.comments(Map.put(set(), "time", value))
    defp with_time(:since, value), do: Wire.comments(put_in(set(), ["complete", "since"], value))

    defp with_time(:comment_created_at, value),
      do: Wire.comments(set_of(Map.put(comment(), "created_at", value)))

    defp with_time(:comment_updated_at, value),
      do: Wire.comments(set_of(Map.put(comment(), "updated_at", value)))

    @times ~w(time created_at updated_at started_at comments_time since comment_created_at comment_updated_at)a

    test "each is RFC 3339 in UTC with whole seconds, and nothing else" do
      for member <- @times do
        assert {:ok, _} = with_time(member, "2026-02-28T23:59:59Z"), "#{member}"

        for value <- [
              "2026-10-15T12:00:00.5Z",
              "2026-10-15T14:00:00+02:00",
              "2026-10-15T12:00:00+00:00",
              "2026-10-15T12:00:00z",
              "2026-10-15t12:00:00Z",
              "2026-10-15 12:00:00Z",
              "2026-10-15T12:00:00",
              "2026-02-30T12:00:00Z",
              "2016-12-31T23:59:60Z",
              "2026-10-15T24:00:00Z",
              " 2026-10-15T12:00:00Z",
              "2026-10-15T12:00:00Z\n",
              String.duplicate("2", 100_000),
              1_760_529_600,
              nil
            ] do
          assert with_time(member, value) == :error, "#{member} #{inspect(value)}"
        end
      end
    end
  end

  describe "a ref named twice" do
    test "is taken once, with the later updated_at, wherever it is named" do
      older = Map.put(item(), "updated_at", "2026-10-14T08:00:00Z")
      newer = Map.merge(item(), %{"updated_at" => "2026-10-14T09:00:00Z", "title" => "Newer"})
      other = Map.put(item(), "ref", "TRK-2")

      for items <- [[older, other, newer], [newer, other, older]] do
        assert {:ok, %{items: decoded}} = Wire.items(Map.put(event(), "items", items))

        assert [%{ref: "TRK-1231", title: "Newer"}, %{ref: "TRK-2"}] =
                 Enum.sort_by(decoded, & &1.ref)

        assert length(decoded) == 2
      end

      assert {:ok, %{items: [%{ref: "TRK-2"}, %{ref: "TRK-1231", title: "Newer"}]}} =
               Wire.items(Map.put(event(), "items", [older, other, newer]))

      deleted = Map.merge(comment(), %{"deleted" => true, "updated_at" => "2026-10-15T09:00:00Z"})

      assert {:ok, %{comments: [%{deleted: true}, %{ref: "C-12"}]}} =
               Wire.comments(
                 Map.put(set(), "comments", [deleted, Enum.at(set()["comments"], 1), comment()])
               )
    end

    test "with the same updated_at, as named last" do
      first = Map.put(item(), "title", "First")
      last = Map.put(item(), "title", "Last")

      assert {:ok, %{items: [%{title: "Last"}]}} =
               Wire.items(Map.put(event(), "items", [first, last]))

      assert {:ok, %{comments: [%{body: "Last"}]}} =
               Wire.comments(
                 Map.put(set(), "comments", [
                   Map.put(comment(), "body", "First"),
                   Map.put(comment(), "body", "Last")
                 ])
               )
    end
  end

  describe "bounded first" do
    # Generous for a shared machine: a refused body takes well under a second here.
    @quick_ms 1000

    defp quick(fun) do
      {microseconds, result} = :timer.tc(fun)
      assert div(microseconds, 1000) < @quick_ms, "took #{div(microseconds, 1000)} ms"
      result
    end

    test "a raw body one byte over 1 MiB is refused undecoded" do
      assert Wire.max_bytes() == 1024 * 1024
      raw = fixture("source-items/code-host-event.json")
      at_limit = raw <> String.duplicate(" ", Wire.max_bytes() - byte_size(raw))

      assert {:ok, _} = Wire.items(at_limit)
      assert quick(fn -> Wire.items(at_limit <> " ") end) == :error

      raw = fixture("source-item-comments/acme-tracker-complete.json")
      at_limit = raw <> String.duplicate(" ", Wire.max_bytes() - byte_size(raw))
      assert {:ok, _} = Wire.comments(at_limit)
      assert quick(fn -> Wire.comments(at_limit <> " ") end) == :error
    end

    test "a body near 1 MiB of many small elements is refused quickly" do
      mib = 1024 * 1024
      item = Jason.encode!(item())
      head = ~s({"version":1,"time":"2026-10-15T12:00:00Z","collection_ref":"TRK","items":)

      comments_head =
        ~s({"version":1,"time":"2026-10-15T12:00:00Z","item_ref":"TRK-1","comments":)

      many_labels = "[" <> Enum.map_join(1..170_000, ",", &~s("#{rem(&1, 10)}")) <> "]"

      items_bodies = [
        head <> "[" <> Enum.map_join(1..340_000, ",", fn _ -> "1" end) <> "]}",
        head <> "[" <> Enum.map_join(1..2_000, ",", fn _ -> item end) <> "]}",
        head <> "[" <> String.replace(item, ~s("labels":[]), ~s("labels":) <> many_labels) <> "]}",
        "{" <> Enum.map_join(1..80_000, ",", &~s("k#{&1}":1)) <> "}",
        head <>
          "[" <>
          String.replace(
            item,
            ~s("ref":),
            Enum.map_join(1..60_000, "", &~s("k#{&1}":1,)) <> ~s("ref":)
          ) <> "]}",
        head <>
          "[" <>
          String.replace(
            item,
            ~s("ref":),
            ~s("target":{) <>
              Enum.map_join(1..60_000, "", &~s("k#{&1}":1,)) <>
              ~s("system":"a","path":"b"},"ref":)
          ) <> "]}",
        head <>
          "[]," <>
          ~s("listing":{) <>
          Enum.map_join(1..60_000, "", &~s("k#{&1}":1,)) <>
          ~s("id":"a","part":1,"started_at":"2026-10-15T12:00:00Z","complete":true}})
      ]

      comments_bodies = [
        comments_head <>
          "[]," <>
          ~s("complete":{) <>
          Enum.map_join(1..60_000, "", &~s("k#{&1}":1,)) <> ~s("since":"2026-10-15T12:00:00Z"}}),
        comments_head <> "[" <> Enum.map_join(1..340_000, ",", fn _ -> "{}" end) <> "]}",
        comments_head <>
          "[" <> Enum.map_join(1..3_000, ",", fn _ -> Jason.encode!(comment()) end) <> "]}"
      ]

      for body <- items_bodies do
        assert byte_size(body) <= mib
        assert quick(fn -> Wire.items(body) end) == :error
      end

      for body <- comments_bodies do
        assert byte_size(body) <= mib
        assert quick(fn -> Wire.comments(body) end) == :error
      end
    end
  end
end
