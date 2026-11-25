defmodule Apiary.Artifacts.ChangeEntryTest do
  # The `change_request` entry of a stored version of a delivered type
  # (`Apiary.Artifacts.ChangeEntry`), against the contract's fixtures of such entries and
  # the pull request schema of the Qory harness.
  use ExUnit.Case, async: true

  alias Apiary.Adapters.ChangeRequest
  alias Apiary.Artifacts.ChangeEntry
  alias Apiary.QoryHarnessFixture

  @fixtures Path.expand("../../fixtures/integration-contract/adapter/changes", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  # The facts of `entry`, a contract fixture's entry, as the writer passes them.
  defp facts(entry, overrides \\ %{}) do
    Map.merge(
      %{
        change_request_id: entry["change_request_id"],
        change_kind: entry["change_kind"],
        work_item_title: "The checkout keeps the old price",
        ref: entry["ref"],
        previous: entry["previous"]
      },
      overrides
    )
  end

  defp commit(n) do
    hex = n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0")

    %{
      "collection" => "R_1001",
      "address" => %{"system" => "code.example.com", "path" => hex}
    }
  end

  describe "build/3" do
    test "builds each pull request entry of the contract's fixtures from its data" do
      schema = QoryHarnessFixture.pull_request_schema()

      for name <- ~w(change-request-pull-request.json change-request-pull-request-one-commit.json
                     change-request-pull-request-two-versions.json) do
        for entry <- fixture(name)["changes"] do
          assert ChangeEntry.build(entry["data"], schema, facts(entry)) == {:ok, entry}, name
          assert ChangeRequest.validate(entry) == :ok, name
        end
      end
    end

    test "cuts the commits to the newest 100 and counts those left out" do
      [expected] = fixture("change-request-pull-request-earlier-commits.json")["changes"]
      assert length(expected["data"]["commits"]) == 100
      assert expected["data"]["earlier_commits"] == 40

      # The run stored 140 commits, the newest last, and no count.
      stored =
        expected["data"]
        |> Map.put("commits", Enum.map(1..140, &commit/1))
        |> Map.delete("earlier_commits")

      schema = QoryHarnessFixture.pull_request_schema()
      assert {:ok, entry} = ChangeEntry.build(stored, schema, facts(expected))
      assert entry["data"]["commits"] == Enum.map(41..140, &commit/1)
      assert entry["data"]["earlier_commits"] == 40
      assert entry["data"]["steps"] == stored["steps"]

      # A stored count adds to those cut.
      assert {:ok, entry} =
               ChangeEntry.build(Map.put(stored, "earlier_commits", 5), schema, facts(expected))

      assert entry["data"]["earlier_commits"] == 45

      # 100 commits or fewer are left as they are.
      hundred = Map.put(stored, "commits", Enum.map(1..100, &commit/1))
      assert {:ok, entry} = ChangeEntry.build(hundred, schema, facts(expected))
      assert entry["data"] == hundred
    end

    test "takes the work item's title and an empty text where the schema has no such member" do
      [reply] = fixture("change-request-reply.json")["changes"]
      content = Map.put(reply["data"], "target", reply["target"])

      assert {:ok, entry} = ChangeEntry.build(content, %{"type" => "object"}, facts(reply))
      assert entry["title"] == "The checkout keeps the old price"
      assert entry["text"] == ""
      assert entry["data"] == content
    end

    test "builds the contract's reply entry from the members that refer to the primitives" do
      primitives = "https://qory.dev/contracts/harness/v1/primitives.schema.json#/$defs/"
      [reply] = fixture("change-request-reply.json")["changes"]

      schema = %{
        "type" => "object",
        "properties" => %{
          "subject" => %{"$ref" => primitives <> "title"},
          "message" => %{"$ref" => primitives <> "text"}
        }
      }

      content = %{
        "target" => reply["target"],
        "subject" => reply["title"],
        "message" => reply["text"],
        "conversation" => "cv_1042"
      }

      assert ChangeEntry.build(content, schema, facts(reply)) ==
               {:ok, %{reply | "data" => content}}

      assert ChangeRequest.validate(%{reply | "data" => content}) == :ok
    end

    test "keeps only the members of target and previous that the feed's entry has" do
      address = %{"system" => "code.example.com", "path" => "acme/shop"}
      url = "https://code.example.com/acme/shop/pull/7"

      content = %{
        "target" => %{
          "collection" => "R_1001",
          "kind" => "branch",
          "address" => Map.put(address, "port", 443)
        }
      }

      previous = %{
        "title" => "Keep the sale price",
        "address" => %{"url" => url, "ref" => "7", "state" => "open"},
        "number" => 7
      }

      assert {:ok, entry} = ChangeEntry.build(content, %{}, facts(%{}, %{previous: previous}))
      assert entry["target"] == %{"collection" => "R_1001", "address" => address}

      assert entry["previous"] == %{
               "title" => "Keep the sale price",
               "address" => %{"url" => url, "ref" => "7"}
             }

      assert entry["data"] == content
    end

    test "follows the schema's $defs to the primitives, each once" do
      primitives = "https://qory.dev/contracts/harness/v1/primitives.schema.json#/$defs/"

      schema = %{
        "properties" => %{
          "heading" => %{"$ref" => "#/$defs/a"},
          "body" => %{"$ref" => primitives <> "text"},
          "loop" => %{"$ref" => "#/$defs/loop"}
        },
        "$defs" => %{
          "a" => %{"$ref" => "#/$defs/b"},
          "b" => %{"$ref" => primitives <> "title"},
          "loop" => %{"$ref" => "#/$defs/loop"}
        }
      }

      content = %{
        "target" => %{"collection" => "SUPPORT"},
        "heading" => "Delivery dates",
        "body" => "Shown at checkout.",
        "loop" => "x"
      }

      assert {:ok, entry} = ChangeEntry.build(content, schema, facts(%{}))
      assert {entry["title"], entry["text"]} == {"Delivery dates", "Shown at checkout."}
      assert ChangeEntry.title(content, schema) == "Delivery dates"
    end

    test "leaves out ref and previous where they are nil" do
      [reply] = fixture("change-request-reply.json")["changes"]
      content = Map.put(reply["data"], "target", reply["target"])

      assert {:ok, entry} =
               ChangeEntry.build(content, %{}, facts(reply, %{ref: nil, previous: nil}))

      refute Map.has_key?(entry, "ref")
      refute Map.has_key?(entry, "previous")
    end

    test "is no entry for content with no target" do
      for content <- [%{}, %{"target" => "R_1001"}, %{"title" => "A change"}] do
        assert ChangeEntry.build(content, %{}, facts(%{})) == :no_target
      end
    end
  end
end
