defmodule Apiary.Lingo.DomainTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Lingo.Domain
  alias Apiary.Lingo.Domain.{Example, Software}
  alias Apiary.Organisations.Workspace

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

    test "its name is the modifier of its locales" do
      assert Software.name() == "software"
    end
  end

  describe "the registry" do
    test "names every domain by the name it gives itself, the software domain the default" do
      assert Domain.domains()["software"] == Software
      assert Domain.default() == Software
      assert "software" in Domain.names()

      for {name, domain} <- Domain.domains() do
        assert domain.name() == name
      end
    end
  end

  describe "a workspace's domain" do
    test "a new workspace is of the default domain, stored by name" do
      %{workspace: workspace} = sign_up_fixture()
      assert workspace.domain == "software"
      assert Repo.reload!(workspace).domain == "software"
      assert Domain.for_workspace(workspace) == Software
    end

    test "is read from the stored name the loaded workspace carries" do
      %{workspace: workspace} = sign_up_fixture()
      set_domain(workspace, "example")
      workspace = Repo.reload!(workspace)

      assert Domain.for_workspace(workspace) == Example

      assert Domain.target(workspace, %{"platform" => "ads.example", "account" => "42"}) ==
               {:ok, %{system: "ads.example", path: "42"}}

      assert Domain.target_labels(workspace) == ["platform", "account"]
    end

    test "without a workspace, or with a name no domain has, it is the default" do
      %{workspace: workspace} = sign_up_fixture()
      set_domain(workspace, "retired")

      assert Domain.for_workspace(Repo.reload!(workspace)) == Software
      assert Domain.for_workspace(%Workspace{domain: "retired"}) == Software
      assert Domain.for_workspace(nil) == Software
    end

    test "is chosen at creation among the domains there are" do
      changeset = Workspace.create_changeset(%Workspace{}, %{name: "Ops", domain: "example"})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :domain) == "example"

      changeset = Workspace.create_changeset(%Workspace{}, %{name: "Ops", domain: "unknown"})
      assert %{domain: ["is invalid"]} = errors_on(changeset)
    end

    test "a rename leaves the domain as it is" do
      changeset = Workspace.changeset(%Workspace{domain: "example"}, %{name: "Ops", domain: "x"})
      assert Ecto.Changeset.get_field(changeset, :domain) == "example"
    end
  end

  describe "Apiary.Lingo.Domain" do
    test "target/2 asks the workspace's domain, and labels that are not a map name none" do
      workspace = %Workspace{domain: "software"}

      assert Domain.target(workspace, @labels) ==
               {:ok, %{system: "git.example.com", path: "acme/shop"}}

      assert Domain.target(workspace, %{"task" => "fix"}) == :none

      for labels <- [nil, "forge=git.example.com", [{"forge", "git.example.com"}], 7] do
        assert Domain.target(workspace, labels) == :none, inspect(labels)
      end
    end

    test "target_labels/1 asks the workspace's domain" do
      assert Domain.target_labels(%Workspace{domain: "software"}) == Software.target_labels()
      assert Domain.target_labels(nil) == Software.target_labels()
    end
  end

  defp set_domain(%Workspace{id: id}, name),
    do: Repo.update_all(from(w in Workspace, where: w.id == ^id), set: [domain: name])
end
