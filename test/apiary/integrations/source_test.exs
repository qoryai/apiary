defmodule Apiary.Integrations.SourceTest do
  use ExUnit.Case, async: true

  alias Apiary.Integrations.Source

  @forges %{
    "github.example.com" => "github",
    "gitlab.example.com" => "gitlab",
    "git.example.com" => "forgejo"
  }

  describe "a forge path" do
    test "implies its kind on the public forges, and may repeat it" do
      assert {:ok,
              %Source{
                form: :forge,
                forge_kind: "github",
                host: "github.com",
                path: "qoryai/qory-github"
              }} =
               Source.parse("github.com/qoryai/qory-github", nil)

      assert {:ok, %Source{forge_kind: "gitlab"}} =
               Source.parse("gitlab.com/acme/tools/qory-webhook", "")

      assert {:ok, %Source{forge_kind: "forgejo"}} =
               Source.parse("codeberg.org/acme/shop", "forgejo")

      assert {:error, :forge_kind_invalid} = Source.parse("github.com/acme/shop", "gitlab")
    end

    test "takes its kind from the operator's list on a forge listed there" do
      assert {:ok,
              %Source{
                form: :forge,
                forge_kind: "forgejo",
                host: "git.example.com",
                path: "acme/shop"
              }} = Source.parse("git.example.com/acme/shop", nil, forge_hosts: @forges)

      assert {:ok, %Source{forge_kind: "gitlab"}} =
               Source.parse("gitlab.example.com/acme/tools/shop", "gitlab", forge_hosts: @forges)

      assert {:ok, %Source{forge_kind: "github"}} =
               Source.parse("github.example.com/acme/shop", "", forge_hosts: @forges)

      for kind <- ["github", "gitea"] do
        assert {:error, :forge_kind_invalid} =
                 Source.parse("git.example.com/acme/shop", kind, forge_hosts: @forges)
      end

      assert {:error, :path_invalid} =
               Source.parse("github.example.com/acme/tools/shop", nil, forge_hosts: @forges)
    end

    test "is refused on a host neither public nor listed, whatever kind it gives" do
      for kind <- [nil, "forgejo", "gitlab"] do
        assert {:error, :forge_host_unlisted} =
                 Source.parse("forge.example.com/acme/shop", kind, forge_hosts: @forges)

        assert {:error, :forge_host_unlisted} =
                 Source.parse("git.example.com/acme/shop", kind, forge_hosts: %{})
      end
    end

    test "on a public forge is not changed by the operator's list" do
      assert {:ok, %Source{forge_kind: "github"}} =
               Source.parse("github.com/acme/shop", nil, forge_hosts: %{"github.com" => "gitlab"})
    end

    test "is owner/repo on GitHub and Forgejo, any depth on GitLab" do
      assert {:error, :path_invalid} = Source.parse("github.com/acme/tools/shop", nil)
      assert {:ok, _} = Source.parse("gitlab.com/acme/tools/sub/shop", nil)
    end

    test "refuses what the contract's grammar refuses" do
      for source <- [
            "github.com/acme",
            "github.com/acme/shop.git",
            "github.com/acme/shop\n",
            "GitHub.com/acme/shop",
            "203.0.113.10/acme/shop",
            "localhost/acme/shop",
            "git.example.com:8443/acme/shop",
            "user@github.com/acme/shop",
            "github.com/acme/../shop",
            "github.com/acme/%2e%2e",
            "git.local/acme/shop",
            "forge.internal/acme/shop",
            "box.home.arpa/acme/shop",
            "https://github.com/acme/shop"
          ] do
        assert {:error, _} = Source.parse(source, "forgejo", forge_hosts: @forges),
               inspect(source)
      end
    end
  end

  describe "a URL source" do
    test "is an https URL of a description.json, with no kind" do
      url = "https://downloads.example.com/qory-jira/1.4.0/description.json"
      assert {:ok, %Source{form: :url, host: "downloads.example.com"}} = Source.parse(url, nil)
      assert {:error, :forge_kind_invalid} = Source.parse(url, "github")
    end

    test "is refused while the operator has them off" do
      url = "https://downloads.example.com/qory-jira/1.4.0/description.json"
      assert {:error, :url_sources_off} = Source.parse(url, nil, url_sources: false)
      assert {:ok, %Source{form: :url}} = Source.parse(url, nil, url_sources: true)

      assert {:ok, %Source{form: :forge}} =
               Source.parse("github.com/acme/shop", nil, url_sources: false)
    end

    test "refuses http, another file, a port, an address and a trailing newline" do
      for url <- [
            "http://downloads.example.com/description.json",
            "https://downloads.example.com/other.json",
            "https://downloads.example.com:8443/description.json",
            "https://203.0.113.10/description.json",
            "https://downloads.example.com/description.json\n",
            "https://user@downloads.example.com/description.json",
            "https://downloads.local/description.json"
          ] do
        assert {:error, :source_invalid} = Source.parse(url, nil), inspect(url)
      end
    end
  end

  test "a version is X.Y.Z with no leading zeros" do
    assert Source.version?("0.1.0")
    assert Source.version?("12.40.3")
    refute Source.version?("01.4.0")
    refute Source.version?("1.4")
    refute Source.version?("v1.4.0")
    refute Source.version?("1.4.0\n")
    refute Source.version?("1.4.0-rc.1")
  end

  test "a file of a release is where its forge publishes it" do
    {:ok, github} = Source.parse("github.com/qoryai/qory-github", nil)
    {:ok, forgejo} = Source.parse("git.example.com/acme/shop", "forgejo", forge_hosts: @forges)
    {:ok, gitlab} = Source.parse("gitlab.com/acme/tools/qory-webhook", nil)

    {:ok, url} =
      Source.parse("https://downloads.example.com/qory-jira/1.4.0/description.json", nil)

    assert Source.download_url(github, "0.1.0", "description.json") ==
             "https://github.com/qoryai/qory-github/releases/download/v0.1.0/description.json"

    assert Source.download_url(forgejo, "2.1.0", "checksums.txt") ==
             "https://git.example.com/acme/shop/releases/download/v2.1.0/checksums.txt"

    assert Source.download_url(gitlab, "1.1.0", "description.json") ==
             "https://gitlab.com/acme/tools/qory-webhook/-/releases/v1.1.0/downloads/description.json"

    assert Source.download_url(url, nil, "checksums.txt") ==
             "https://downloads.example.com/qory-jira/1.4.0/checksums.txt"
  end

  test "a file of a release on a listed forge is where a forge of its kind publishes it" do
    {:ok, github} = Source.parse("github.example.com/acme/shop", nil, forge_hosts: @forges)
    {:ok, gitlab} = Source.parse("gitlab.example.com/acme/tools/shop", nil, forge_hosts: @forges)
    {:ok, forgejo} = Source.parse("git.example.com/acme/shop", nil, forge_hosts: @forges)

    assert Source.download_url(github, "1.2.0", "description.json") ==
             "https://github.example.com/acme/shop/releases/download/v1.2.0/description.json"

    assert Source.download_url(gitlab, "1.2.0", "description.json") ==
             "https://gitlab.example.com/acme/tools/shop/-/releases/v1.2.0/downloads/description.json"

    assert Source.download_url(forgejo, "1.2.0", "checksums.txt") ==
             "https://git.example.com/acme/shop/releases/download/v1.2.0/checksums.txt"
  end

  test "the owner a person can check, and which forges are public" do
    {:ok, github} = Source.parse("github.com/qoryai/qory-github", nil)
    {:ok, gitlab} = Source.parse("gitlab.com/acme/tools/qory-webhook", nil)
    {:ok, forgejo} = Source.parse("git.example.com/acme/shop", "forgejo", forge_hosts: @forges)
    {:ok, url} = Source.parse("https://downloads.example.com/description.json", nil)

    assert Source.owner(github) == "github.com/qoryai"
    assert Source.owner(gitlab) == "gitlab.com/acme/tools"
    assert Source.owner(url) == "downloads.example.com"

    assert Source.public_forge?(github)
    refute Source.public_forge?(forgejo)
    refute Source.public_forge?(url)
  end

  describe "INTEGRATION_FORGE_HOSTS" do
    test "is forges, each its kind, a colon and its host, separated by commas" do
      assert Source.parse_forge_hosts(nil) == {:ok, %{}}
      assert Source.parse_forge_hosts(" ") == {:ok, %{}}

      assert Source.parse_forge_hosts(
               "github:github.example.com, GitLab:GitLab.Example.com,,forgejo : git.example.com"
             ) == {:ok, @forges}

      assert Source.parse_forge_hosts("forgejo:git.example.com,forgejo:git.example.com") ==
               {:ok, %{"git.example.com" => "forgejo"}}
    end

    test "refuses an entry that is not a kind and a host name" do
      for {setting, reason} <- [
            {"git.example.com", "is not a kind"},
            {"gitea:git.example.com", "is not a kind"},
            {"forgejo:", "is not a kind"},
            {"forgejo:10.0.0.1", "is not a kind"},
            {"forgejo:git.example.com:3000", "is not a kind"},
            {"forgejo:https://git.example.com", "is not a kind"},
            {"forgejo:forge.local", "is not a kind"},
            {"forgejo:localhost", "is not a kind"},
            {"gitlab:gitlab.com", "public forge"},
            {"forgejo:git.example.com,gitlab:git.example.com", "listed as forgejo and as gitlab"}
          ] do
        assert {:error, message} = Source.parse_forge_hosts(setting), setting
        assert message =~ reason, setting
      end
    end
  end

  describe "INTEGRATION_URL_SOURCES" do
    test "is on unless turned off, in the spellings of the other switches" do
      for value <- [nil, "", " ", "true", "TRUE", "1", "yes"] do
        assert Source.parse_url_sources(value) == {:ok, true}, inspect(value)
      end

      for value <- ["false", "False", "0", "no", " no "] do
        assert Source.parse_url_sources(value) == {:ok, false}, inspect(value)
      end

      for value <- ["off", "maybe", "2"] do
        assert {:error, reason} = Source.parse_url_sources(value)
        assert reason =~ "true or false"
      end
    end
  end
end
