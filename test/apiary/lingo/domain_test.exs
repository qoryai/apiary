defmodule Apiary.Lingo.DomainTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Lingo.Domain
  alias Apiary.Lingo.Domain.{Example, General, Software}
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

    test "its label of a run's paths is repositories, the plural of the path's" do
      assert Software.paths_label() == "repositories"
    end

    test "its name is the modifier of its locales" do
      assert Software.name() == "software"
    end

    test "a work item needs a target, and its environment is prebuilt" do
      assert Software.target_required?()
      assert Software.prebuilds?()
    end

    test "a target may have a harness file" do
      assert Software.harness_file?()
    end

    test "a target is a host name and an owner/name path with no segment led by a dash" do
      assert Software.check_target(%{system: "git.example.com", path: "acme/shop"}) == :ok

      for {system, path} <- [
            {"git.example.com", "shop"},
            {"git.example.com", "acme/shop/web"},
            {"git.example.com", "-acme/shop"},
            {"git.example.com", "acme/-shop"},
            {"git.example.com", "acme shop/web"},
            {".git.example.com", "acme/shop"},
            {"git..example.com", "acme/shop"},
            {"Git.Example.com", "acme/shop"}
          ] do
        assert Software.check_target(%{system: system, path: path}) == {:error, :target_invalid},
               inspect({system, path})
      end
    end

    test "a run gets QORY_RUN_SYSTEM and QORY_RUN_REPOSITORIES, the target first" do
      assert Software.run_variables(%{system: "git.example.com", path: "acme/shop"}, ["acme/lib"]) ==
               {:ok,
                %{
                  "QORY_RUN_SYSTEM" => "git.example.com",
                  "QORY_RUN_REPOSITORIES" => "acme/shop,acme/lib"
                }}

      assert Software.run_variables(%{system: "git.example.com", path: "-acme/shop"}, []) ==
               {:error, :repositories_invalid}
    end
  end

  describe "the general domain" do
    @general %{"system" => "ads.example.com", "path" => "accounts/1234"}

    test "the system label is the system and the path label the path" do
      assert General.target(@general) ==
               {:ok, %{system: "ads.example.com", path: "accounts/1234"}}

      assert General.target(Map.delete(@general, "path")) == :none
      assert General.target(Map.put(@general, "system", "a\nb")) == :none
      assert General.target(@labels) == :none
      assert General.target_labels() == ["system", "path"]
    end

    test "is named general, with no label of a run's paths" do
      assert General.name() == "general"
      refute function_exported?(General, :paths_label, 0)
    end

    test "a work item needs no target, a run gets no variables, and nothing is prebuilt" do
      refute General.target_required?()
      refute General.prebuilds?()
      refute General.harness_file?()

      assert General.run_variables(%{system: "ads.example.com", path: "accounts/1234"}, []) ==
               {:ok, nil}
    end

    test "a target is a host name and any path of 1 to 200 characters that can be a label" do
      for path <- ["accounts/1234", "one", "a/b/c", "-led by a dash", String.duplicate("a", 200)] do
        assert General.check_target(%{system: "ads.example.com", path: path}) == :ok, path
      end

      for {system, path} <- [
            {"ads.example.com", ""},
            {"ads.example.com", String.duplicate("a", 201)},
            {"ads.example.com", "a\tb"},
            {"Ads.example.com", "one"},
            {"ads..example.com", "one"},
            {"ads.example.com.", "one"},
            {"ads example", "one"}
          ] do
        assert General.check_target(%{system: system, path: path}) == {:error, :target_invalid},
               inspect({system, path})
      end
    end
  end

  describe "the registry" do
    test "names every domain by the name it gives itself, the software domain the default" do
      assert Domain.domains()["software"] == Software
      assert Domain.domains()["general"] == General
      assert Domain.default() == Software
      assert "software" in Domain.names()
      assert "general" in Domain.names()

      for {name, domain} <- Domain.domains() do
        assert domain.name() == name
      end
    end

    test "offers the domains as choices, the default first, then the others by name" do
      assert Domain.choices() == [Software, Example, General]
      assert Enum.sort(Enum.map(Domain.choices(), & &1.name())) == Domain.names()
    end
  end

  describe "a domain's label and description" do
    test "the software domain is a software workspace, for work on code" do
      assert Software.label() == "Software workspace"

      assert Software.description() ==
               "For work on code. Each ticket needs a repository, and Qory reads the repository's code."
    end

    test "the general domain is a general workspace, for any other work" do
      assert General.label() == "General workspace"

      assert General.description() ==
               "For any other work, such as marketing, incidents or customer care. Qory reads the ticket, its comments and the answers."
    end

    test "each reads the same in a software workspace's locale and in a general one's" do
      for domain <- [Software, General] do
        words =
          for locale <- ["en@software", "en@general"],
              do:
                Gettext.with_locale(ApiaryWeb.Gettext, locale, fn ->
                  {domain.label(), domain.description()}
                end)

        assert words == List.duplicate({domain.label(), domain.description()}, 2)
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

    test "name/1 is the name of the workspace's domain, the default's for none or a retired one" do
      assert Domain.name(%Workspace{domain: "general"}) == "general"
      assert Domain.name(%Workspace{domain: "example"}) == "example"
      assert Domain.name(%Workspace{domain: "retired"}) == "software"
      assert Domain.name(nil) == "software"
    end

    test "target_labels/1 asks the workspace's domain" do
      assert Domain.target_labels(%Workspace{domain: "software"}) == Software.target_labels()
      assert Domain.target_labels(nil) == Software.target_labels()
    end

    test "paths_label/1 asks the workspace's domain, nil for a domain without one" do
      assert Domain.paths_label(%Workspace{domain: "software"}) == "repositories"
      assert Domain.paths_label(nil) == "repositories"
      assert Domain.paths_label(%Workspace{domain: "example"}) == nil
    end

    test "target_required?/1 and prebuilds?/1 ask the workspace's domain" do
      assert Domain.target_required?(%Workspace{domain: "software"})
      assert Domain.target_required?(nil)
      refute Domain.target_required?(%Workspace{domain: "general"})
      assert Domain.prebuilds?(%Workspace{domain: "software"})
      refute Domain.prebuilds?(%Workspace{domain: "general"})
      refute Domain.prebuilds?(%Workspace{domain: "example"})
    end

    test "harness_file?/1 asks the workspace's domain" do
      assert Domain.harness_file?(%Workspace{domain: "software"})
      assert Domain.harness_file?(nil)
      refute Domain.harness_file?(%Workspace{domain: "general"})
      refute Domain.harness_file?(%Workspace{domain: "example"})
    end

    test "check_target/2 refuses no target only where the domain needs one" do
      assert Domain.check_target(%Workspace{domain: "software"}, nil) == {:error, :no_target}
      assert Domain.check_target(%Workspace{domain: "general"}, nil) == :ok
      assert Domain.check_target(%Workspace{domain: "example"}, nil) == :ok

      target = %{system: "ads.example.com", path: "accounts/1234/campaigns"}

      assert Domain.check_target(%Workspace{domain: "software"}, target) ==
               {:error, :target_invalid}

      assert Domain.check_target(%Workspace{domain: "general"}, target) == :ok
    end

    test "run_variables/3 gives none without a target, else asks the workspace's domain" do
      assert Domain.run_variables(%Workspace{domain: "software"}, nil, []) == {:ok, nil}

      assert {:ok, %{"QORY_RUN_SYSTEM" => "git.example.com"}} =
               Domain.run_variables(
                 %Workspace{domain: "software"},
                 %{system: "git.example.com", path: "acme/shop"},
                 []
               )

      assert Domain.run_variables(
               %Workspace{domain: "general"},
               %{system: "ads.example.com", path: "accounts/1234"},
               []
             ) == {:ok, nil}
    end

    test "serves?/2: an adapter that lists no domains serves every workspace" do
      assert Domain.serves?(nil, %Workspace{domain: "general"})
      assert Domain.serves?(["software"], %Workspace{domain: "software"})
      refute Domain.serves?(["software"], %Workspace{domain: "general"})
      assert Domain.serves?(["marketing", "general"], %Workspace{domain: "general"})
      # A stored name no domain has reads the default, as every read of it does.
      assert Domain.serves?(["software"], %Workspace{domain: "retired"})
    end

    test "host?/1 is a host name with no empty label" do
      assert Domain.host?("git.example.com")
      assert Domain.host?("localhost")

      for system <- ["", ".a", "a.", "a..b", "A.b", "a_b", String.duplicate("a", 254), nil, 7] do
        refute Domain.host?(system), inspect(system)
      end
    end
  end

  defp set_domain(%Workspace{id: id}, name),
    do: Repo.update_all(from(w in Workspace, where: w.id == ^id), set: [domain: name])
end
