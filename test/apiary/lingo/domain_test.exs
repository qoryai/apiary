defmodule Apiary.Lingo.DomainTest do
  use ExUnit.Case, async: true

  alias Apiary.Lingo.Domain
  alias Apiary.Lingo.Domain.Software

  @labels %{"forge" => "git.example.com", "repository" => "acme/shop"}

  describe "the software domain" do
    test "the forge label is the system and the repository label the path" do
      assert Software.target(@labels) == {:ok, %{system: "git.example.com", path: "acme/shop"}}
    end

    test "any other label names nothing and is ignored" do
      labels = Map.merge(@labels, %{"task" => "fix", "issue" => "77", "system" => "other"})
      assert Software.target(labels) == {:ok, %{system: "git.example.com", path: "acme/shop"}}
    end

    test "without both labels, or with one that cannot name a target, the labels name none" do
      bad = [
        "",
        "acme/shop\n# injected: true",
        "acme/\tshop",
        "acme/shop\u2028",
        "acme/\u0000shop",
        String.duplicate("a", 257),
        <<255>>,
        7,
        nil,
        ["acme/shop"],
        %{"a" => "acme/shop"}
      ]

      for key <- ["forge", "repository"] do
        assert Software.target(Map.delete(@labels, key)) == :none, key

        for value <- bad do
          assert Software.target(Map.put(@labels, key, value)) == :none, inspect({key, value})
        end
      end

      assert Software.target(%{}) == :none
      assert Software.target(%{"system" => "git.example.com", "path" => "acme/shop"}) == :none
    end

    test "a label as long as a target's may be is read" do
      path = String.duplicate("a", 256)

      assert Software.target(Map.put(@labels, "repository", path)) ==
               {:ok, %{system: "git.example.com", path: path}}
    end

    test "its target's labels are forge, then repository" do
      assert Software.target_labels() == ["forge", "repository"]
    end

    test "its words are the software locale" do
      assert Software.locale() == "en@software"
    end
  end

  describe "Apiary.Lingo.Domain" do
    test "every workspace has the software domain" do
      assert Domain.for_workspace(nil) == Software
      assert Domain.for_workspace(Ecto.UUID.generate()) == Software
      assert Domain.for_workspace(%Apiary.Organisations.Workspace{}) == Software
    end

    test "target/2 asks the workspace's domain, and labels that are not a map name none" do
      workspace = Ecto.UUID.generate()

      assert Domain.target(workspace, @labels) ==
               {:ok, %{system: "git.example.com", path: "acme/shop"}}

      assert Domain.target(workspace, %{"task" => "fix"}) == :none

      for labels <- [nil, "forge=git.example.com", [{"forge", "git.example.com"}], 7] do
        assert Domain.target(workspace, labels) == :none, inspect(labels)
      end
    end

    test "target_labels/1 asks the workspace's domain" do
      assert Domain.target_labels(Ecto.UUID.generate()) == Software.target_labels()
    end
  end
end
