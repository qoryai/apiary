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

      assert RunVariables.for_target(target(), ["acme/docs", "acme/tools"]) ==
               {:ok,
                %{
                  @system => "git.example.com",
                  @repositories => "acme/shop,acme/docs,acme/tools"
                }}
    end

    test "the system is a host name of 1 to 253 of a-z, 0-9, dot and dash, no label empty" do
      for system <- ["a", "git.example.com", "git-1.example.com", String.duplicate("a", 253)],
          do: assert({:ok, %{@system => ^system}} = RunVariables.for_target(target(system)))

      for system <- [
            "",
            String.duplicate("a", 254),
            "git.example.com.",
            "forge.example.com..",
            "forge..example.com",
            ".example.com",
            "Git.example.com",
            "git.example.com:8443",
            "git_example.com",
            "git example.com",
            "git.example.com\n",
            nil
          ],
          do: assert(RunVariables.for_target(target(system)) == {:error, :system_invalid})
    end

    test "every entry is exactly owner/name, two segments of A-Z, a-z, 0-9, dot, underscore and dash" do
      for path <- [
            "acme/shop",
            "Acme-1/shop.web_2",
            "a/b",
            "acme/.config",
            "acme/..x",
            "acme/a-b",
            "a-cme/shop"
          ] do
        assert {:ok, %{@repositories => ^path}} =
                 RunVariables.for_target(target("git.example.com", path))

        # The same path picked beside a target of its owner.
        first = (path |> String.split("/") |> hd()) <> "/first"
        listed = first <> "," <> path

        assert {:ok, %{@repositories => ^listed}} =
                 RunVariables.for_target(target("git.example.com", first), [path])
      end

      for path <- [
            "",
            "shop",
            "acme/",
            "acme/shop/",
            "/shop",
            "acme//shop",
            "acme/sh op",
            "acme/shop,acme/docs",
            "acme/shop\n",
            "acme/sh\u00e9p",
            "acme/.",
            "acme/..",
            "acme/./shop",
            "./shop",
            "acme/.git",
            "acme/.GIT",
            "acme/shop/.git",
            "acme/shop/web",
            "group/sub/team/project",
            "-acme/shop",
            "acme/-rf",
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

    test "no entry twice, compared without case" do
      for picked <- [["acme/shop"], ["acme/Shop"], ["ACME/SHOP"], ["acme/docs", "Acme/Docs"]],
          do: assert(RunVariables.for_target(target(), picked) == {:error, :repositories_invalid})
    end

    test "no entry is nested inside another: an entry of more than two segments is refused" do
      assert RunVariables.for_target(target("git.example.com", "acme/shop/web")) ==
               {:error, :repositories_invalid}

      for picked <- [["acme/shop/web"], ["acme/docs", "acme/docs/web"]],
          do: assert(RunVariables.for_target(target(), picked) == {:error, :repositories_invalid})
    end

    test "every entry is of the first entry's owner, compared without case, on every system" do
      for system <- ["git.example.com", "code.example.org"] do
        assert {:ok, %{@repositories => "acme/shop,acme/docs,ACME/tools,Acme/a"}} =
                 RunVariables.for_target(target(system), ["acme/docs", "ACME/tools", "Acme/a"])

        for picked <- [
              ["other/docs"],
              ["acme/docs", "other/docs"],
              ["other/acme/docs"],
              ["Acme/a/b"]
            ],
            do:
              assert(
                RunVariables.for_target(target(system), picked) ==
                  {:error, :repositories_invalid}
              )
      end
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

  describe "check_repositories/2" do
    test "keeps a list of the target's owner, each once, and an empty one" do
      assert RunVariables.check_repositories("acme/shop", []) == :ok
      assert RunVariables.check_repositories("acme/shop", ["acme/docs", "ACME/tools"]) == :ok
    end

    test "names the first rule broken and the place of its path in the list, counted from 1" do
      check = &RunVariables.check_repositories("acme/shop", &1)

      for path <- [
            "acme",
            "acme/docs/x",
            "acme/",
            "acme/.",
            "acme/..",
            "acme/.Git",
            "acme/-rf",
            "a b/c",
            7
          ],
          do: assert(check.(["acme/docs", path]) == {:error, {:not_a_path, 2}}, inspect(path))

      assert check.(["acme/" <> segment(196)]) == {:error, {:too_long, 1}}
      assert check.(["other/docs"]) == {:error, {:other_owner, 1}}
      assert check.(["Acme/Shop"]) == {:error, {:itself, 1}}
      assert check.(["acme/docs", "acme/api", "ACME/DOCS"]) == {:error, {:repeats, 3}}
      # The first path that breaks one, by the order of the rules for that path.
      assert check.(["acme/api", "other/docs", "not a path"]) == {:error, {:other_owner, 2}}
    end

    test "the target and the list, joined with commas, are at most 256 bytes" do
      first = "acme/" <> segment(195)
      second = "acme/" <> segment(40)
      assert byte_size(Enum.join(["acme/shop", first, second], ",")) == 256

      assert RunVariables.check_repositories("acme/shop", [first, second]) == :ok

      assert RunVariables.check_repositories("acme/shop", [first, second <> "a"]) ==
               {:error, {:too_long_together, 2}}
    end

    test "for_target/2 refuses exactly the lists it refuses" do
      for picked <- [
            ["acme/docs"],
            ["acme"],
            ["acme/-rf"],
            ["other/docs"],
            ["acme/shop"],
            ["acme/docs", "acme/docs"],
            ["acme/" <> segment(195), "acme/" <> segment(41)]
          ] do
        assert match?({:ok, _variables}, RunVariables.for_target(target(), picked)) ==
                 (RunVariables.check_repositories("acme/shop", picked) == :ok),
               inspect(picked)
      end
    end
  end
end
