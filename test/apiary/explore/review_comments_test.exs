defmodule Apiary.Explore.ReviewCommentsTest do
  # A work item's review comments document (`Apiary.Explore.ReviewComments`), with no
  # database: the check of a version a run pushes against the newest version, each reason
  # it refuses one for and the versions it takes, and what members write.
  use ExUnit.Case, async: true

  alias Apiary.Explore.ReviewComments

  @at "2026-11-04T10:00:00Z"
  @on %{"artifact" => "proposal", "version" => 1}

  defp comment(id, state \\ "open", replies \\ []) do
    %{
      "id" => id,
      "on" => @on,
      "text" => "Change #{id}.",
      "by" => %{"name" => "Ann Example"},
      "at" => @at,
      "state" => state
    }
    |> then(&if(replies == [], do: &1, else: Map.put(&1, "replies", replies)))
  end

  defp run_reply(run, outcome \\ "changed", question \\ nil),
    do:
      %{"text" => "Done.", "by" => %{"run" => run}, "at" => @at, "outcome" => outcome}
      |> then(&if(question, do: Map.put(&1, "question", question), else: &1))

  defp member_reply, do: %{"text" => "Not yet.", "by" => %{"name" => "Ann Example"}, "at" => @at}

  defp doc(comments), do: %{"review_comments" => comments}

  describe "check_run/4" do
    test "takes the run's reply to each open review comment, which it closes" do
      newest = doc([comment("c1"), comment("c2", "closed", [run_reply(12)]), comment("c3")])

      pushed =
        doc([
          comment("c1", "closed", [run_reply(13, "answered")]),
          comment("c2", "closed", [run_reply(12)]),
          comment("c3")
        ])

      assert ReviewComments.check_run(newest, pushed, 13, []) == :ok
      assert ReviewComments.check_run(newest, newest, 13, []) == :ok
    end

    test "takes a reply with the outcome asked, for a question the questions have" do
      newest = doc([comment("c1")])
      pushed = doc([comment("c1", "closed", [run_reply(13, "asked", "q3")])])

      assert ReviewComments.check_run(newest, pushed, 13, ["q1", "q3"]) == :ok

      assert ReviewComments.check_run(newest, pushed, 13, ["q1"]) ==
               {:error, :question_unknown}
    end

    test "refuses a version that drops an id, or adds a review comment" do
      newest = doc([comment("c1"), comment("c2")])

      assert ReviewComments.check_run(newest, doc([comment("c1")]), 13, []) ==
               {:error, :id_dropped}

      assert ReviewComments.check_run(
               newest,
               doc([comment("c1"), comment("c2"), comment("c3")]),
               13,
               []
             ) ==
               {:error, :comment_added}

      assert ReviewComments.check_run(nil, doc([comment("c1")]), 13, []) ==
               {:error, :comment_added}
    end

    test "refuses a review comment's on, text, by or at changed" do
      newest = doc([comment("c1")])

      for {key, value} <- [
            {"text", "Another."},
            {"on", %{"artifact" => "proposal", "version" => 2}},
            {"by", %{"name" => "Bo Example"}},
            {"at", "2026-11-04T10:00:01Z"}
          ] do
        assert ReviewComments.check_run(newest, doc([Map.put(comment("c1"), key, value)]), 13, []) ==
                 {:error, :comment_changed}
      end
    end

    test "refuses an earlier reply changed or dropped" do
      newest = doc([comment("c1", "open", [run_reply(12), member_reply()])])

      assert ReviewComments.check_run(
               newest,
               doc([comment("c1", "open", [run_reply(12)])]),
               13,
               []
             ) ==
               {:error, :reply_changed}

      changed = [run_reply(12, "declined"), member_reply()]

      assert ReviewComments.check_run(newest, doc([comment("c1", "open", changed)]), 13, []) ==
               {:error, :reply_changed}
    end

    test "refuses a reply not by the run, and more than one reply" do
      newest = doc([comment("c1")])

      for reply <- [member_reply(), run_reply(12)] do
        assert ReviewComments.check_run(newest, doc([comment("c1", "closed", [reply])]), 13, []) ==
                 {:error, :reply_not_run}
      end

      assert ReviewComments.check_run(
               newest,
               doc([comment("c1", "closed", [run_reply(13), run_reply(13)])]),
               13,
               []
             ) == {:error, :replies_added}
    end

    test "refuses a reply to a closed review comment, and a reply that leaves it open" do
      closed = doc([comment("c1", "closed", [run_reply(12)])])

      assert ReviewComments.check_run(
               closed,
               doc([comment("c1", "closed", [run_reply(12), run_reply(13)])]),
               13,
               []
             ) == {:error, :not_open}

      assert ReviewComments.check_run(
               doc([comment("c1")]),
               doc([comment("c1", "open", [run_reply(13)])]),
               13,
               []
             ) == {:error, :not_closed}
    end

    test "refuses a review comment closed without a reply, or opened" do
      assert ReviewComments.check_run(
               doc([comment("c1")]),
               doc([comment("c1", "closed")]),
               13,
               []
             ) ==
               {:error, :state_changed}

      closed = comment("c1", "closed", [run_reply(12)])

      assert ReviewComments.check_run(
               doc([closed]),
               doc([Map.put(closed, "state", "open")]),
               13,
               []
             ) ==
               {:error, :state_changed}
    end

    test "compares numbers by value, as the schema's integers: 1.0 is 1, 13.0 is run 13" do
      newest = doc([comment("c1"), comment("c2", "closed", [run_reply(12)])])

      assert ReviewComments.check_run(
               newest,
               doc([
                 put_in(comment("c1"), ["on", "version"], 1.0),
                 comment("c2", "closed", [run_reply(12.0)])
               ]),
               13,
               []
             ) == :ok

      assert ReviewComments.check_run(
               newest,
               doc([
                 comment("c1", "closed", [run_reply(13.0)]),
                 comment("c2", "closed", [run_reply(12)])
               ]),
               13,
               []
             ) == :ok

      assert ReviewComments.check_run(
               newest,
               doc([
                 put_in(comment("c1"), ["on", "version"], 2.0),
                 comment("c2", "closed", [run_reply(12)])
               ]),
               13,
               []
             ) == {:error, :comment_changed}
    end
  end

  describe "what members write" do
    test "comment/5 adds an open review comment with the next free id" do
      at = ~U[2026-11-04 12:00:00.5Z]

      assert {"c1", %{"review_comments" => [first]} = document} =
               ReviewComments.comment(nil, @on, "Offer a refund.", "Ann Example", at)

      assert first == %{
               "id" => "c1",
               "on" => @on,
               "text" => "Offer a refund.",
               "by" => %{"name" => "Ann Example"},
               "at" => "2026-11-04T12:00:00Z",
               "state" => "open"
             }

      document = %{document | "review_comments" => [Map.put(first, "id", "c7")]}

      assert {"c8", %{"review_comments" => [_, _]}} =
               ReviewComments.comment(document, @on, "B.", "Ann Example", at)
    end

    test "reply/5 adds a member's reply and opens the review comment again" do
      document = doc([comment("c1", "closed", [run_reply(12)]), comment("c2")])
      at = ~U[2026-11-04 12:00:00Z]

      assert {:ok, %{"review_comments" => [c1, c2]}} =
               ReviewComments.reply(document, "c1", "Not yet.", "Ann Example", at)

      assert c1["state"] == "open"

      assert [
               _,
               %{
                 "text" => "Not yet.",
                 "by" => %{"name" => "Ann Example"},
                 "at" => "2026-11-04T12:00:00Z"
               }
             ] = c1["replies"]

      assert c2 == comment("c2")

      assert ReviewComments.reply(document, "c9", "Not yet.", "Ann Example", at) == :error
    end
  end
end
