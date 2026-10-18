defmodule Apiary.Runs.RunVariablesTest do
  use ExUnit.Case, async: true

  alias Apiary.Runs.{Answer, RunVariables}

  @system "QORY_RUN_SYSTEM"
  @repositories "QORY_RUN_REPOSITORIES"

  defp target(system \\ "git.example.com", path \\ "acme/shop"),
    do: %{system: system, path: path}

  # A segment of `n` characters.
  defp segment(n), do: String.duplicate("a", n)

  describe "for_target/2" do
    test "names the system and the target's repository, first, then the picked ones" do
      assert RunVariables.for_target(target()) ==
               {:ok, %{@system => "git.example.com", @repositories => "acme/shop"}}

      assert RunVariables.for_target(target(), ["acme/docs", "other/tools"]) ==
               {:ok,
                %{
                  @system => "git.example.com",
                  @repositories => "acme/shop,acme/docs,other/tools"
                }}
    end

    test "the system is a host name of 1 to 253 of a-z, 0-9, dot and dash, not ending in a dot" do
      for system <- ["a", "git.example.com", "git-1.example.com", String.duplicate("a", 253)],
          do: assert({:ok, %{@system => ^system}} = RunVariables.for_target(target(system)))

      for system <- [
            "",
            String.duplicate("a", 254),
            "git.example.com.",
            "Git.example.com",
            "git.example.com:8443",
            "git_example.com",
            "git example.com",
            "git.example.com\n",
            nil
          ],
          do: assert(RunVariables.for_target(target(system)) == {:error, :system_invalid})
    end

    test "every entry is owner/name, of A-Z, a-z, 0-9, dot, underscore and dash" do
      for path <- ["acme/shop", "Acme-1/shop.web_2", "a/b", "acme/.github", "acme/..x"] do
        assert {:ok, %{@repositories => ^path}} =
                 RunVariables.for_target(target("git.example.com", path))

        listed = "other/docs," <> path

        assert {:ok, %{@repositories => ^listed}} =
                 RunVariables.for_target(target("git.example.com", "other/docs"), [path])
      end

      for path <- [
            "",
            "shop",
            "acme/",
            "/shop",
            "acme//shop",
            "acme/shop/web",
            "acme/sh op",
            "acme/shop,acme/docs",
            "acme/shop\n",
            "acme/shép",
            "acme/.",
            "acme/..",
            "./shop",
            "acme/.git",
            "acme/.GIT",
            nil
          ] do
        assert RunVariables.for_target(target("git.example.com", path)) ==
                 {:error, :repositories_invalid}

        assert RunVariables.for_target(target(), [path]) == {:error, :repositories_invalid}
      end
    end

    test "an entry is at most 200 characters" do
      at = segment(100) <> "/" <> segment(99)
      past = segment(100) <> "/" <> segment(100)

      assert {:ok, _} = RunVariables.for_target(target("git.example.com", at))

      assert RunVariables.for_target(target("git.example.com", past)) ==
               {:error, :repositories_invalid}
    end

    test "the list is at most 256 bytes" do
      # "acme/shop", then 14 entries of 16 bytes with a comma before each: 9 + 14 * 17 =
      # 247; a last entry of 8 bytes and its comma make 256, one of 9 bytes 257.
      picked = for n <- 1..14, do: "acme/" <> String.pad_leading("#{n}", 11, "r")

      at = picked ++ ["acme/abc"]
      past = picked ++ ["acme/abcd"]

      assert {:ok, %{@repositories => list}} = RunVariables.for_target(target(), at)
      assert byte_size(list) == 256
      assert RunVariables.for_target(target(), past) == {:error, :repositories_invalid}
    end

    test "no entry twice: the target's repository among the picked ones is one" do
      assert RunVariables.for_target(target(), ["acme/shop"]) == {:error, :repositories_invalid}

      assert RunVariables.for_target(target(), ["acme/docs", "acme/docs"]) ==
               {:error, :repositories_invalid}

      # Elsewhere than github.com, names differ by case.
      assert {:ok, %{@repositories => "acme/shop,acme/Shop"}} =
               RunVariables.for_target(target(), ["acme/Shop"])
    end

    test "on github.com, every entry is of the first one's owner, and no entry twice, in any case" do
      github = target("github.com", "acme/shop")

      assert {:ok, %{@system => "github.com", @repositories => "acme/shop,acme/docs,ACME/tools"}} =
               RunVariables.for_target(github, ["acme/docs", "ACME/tools"])

      assert RunVariables.for_target(github, ["other/docs"]) == {:error, :repositories_invalid}
      assert RunVariables.for_target(github, ["acme/Shop"]) == {:error, :repositories_invalid}

      # Elsewhere, the owners may differ.
      assert {:ok, _} = RunVariables.for_target(target(), ["other/docs"])
    end
  end

  describe "document/1" do
    test "each name, in order, with an object holding its value" do
      variables = %{@system => "git.example.com", @repositories => "acme/shop"}

      assert Jason.encode!(RunVariables.document(variables)) ==
               ~s({"QORY_RUN_REPOSITORIES":{"value":"acme/shop"},) <>
                 ~s("QORY_RUN_SYSTEM":{"value":"git.example.com"}})
    end
  end

  describe "Answer.append_members/2" do
    test "keeps the document's bytes and adds the members after its last one, in order" do
      document = ~s({"version":1,"security_policy":{"mode":"observe","allow":[]}})

      assert Answer.append_members(document, [
               {"variables", %{"A" => %{"value" => "1"}}},
               {"labels", %{"x" => "y"}}
             ]) ==
               ~s({"version":1,"security_policy":{"mode":"observe","allow":[]},) <>
                 ~s("variables":{"A":{"value":"1"}},"labels":{"x":"y"}})

      assert Answer.append_members(~s({"version":1}), [{"labels", %{"x" => "y"}}]) ==
               ~s({"version":1,"labels":{"x":"y"}})

      assert Answer.append_members("{}", [{"labels", %{"x" => "y"}}]) == ~s({"labels":{"x":"y"}})
    end

    test "leaves out a member with nothing in it, and the document as it is with none" do
      document = ~s({"version":1})

      empty = Jason.OrderedObject.new([])

      assert Answer.append_members(document, [
               {"variables", nil},
               {"labels", %{}},
               {"about", empty}
             ]) ==
               document
    end

    test "raises for a member the document has already" do
      document = ~s({"version":1,"variables":{"A":{"value":"1"}}})

      assert_raise ArgumentError, fn ->
        Answer.append_members(document, [{"variables", %{"B" => %{"value" => "2"}}}])
      end

      # Nothing to add, nothing to check.
      assert Answer.append_members(document, [{"variables", nil}]) == document
    end
  end
end
