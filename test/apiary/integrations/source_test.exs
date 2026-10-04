defmodule Apiary.Integrations.SourceTest do
  use ExUnit.Case, async: true

  alias Apiary.Integrations.Source

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

    test "needs its kind on any other host" do
      assert {:error, :forge_kind_required} = Source.parse("git.example.com/acme/shop", nil)

      assert {:ok, %Source{forge_kind: "forgejo"}} =
               Source.parse("git.example.com/acme/shop", "forgejo")

      assert {:error, :forge_kind_invalid} = Source.parse("git.example.com/acme/shop", "gitea")
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
        assert {:error, _} = Source.parse(source, "forgejo"), inspect(source)
      end
    end
  end

  describe "a URL source" do
    test "is an https URL of a description.json, with no kind" do
      url = "https://downloads.example.com/qory-jira/1.4.0/description.json"
      assert {:ok, %Source{form: :url, host: "downloads.example.com"}} = Source.parse(url, nil)
      assert {:error, :forge_kind_invalid} = Source.parse(url, "github")
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
    {:ok, forgejo} = Source.parse("git.example.com/acme/shop", "forgejo")
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

  test "the owner a person can check, and which forges are public" do
    {:ok, github} = Source.parse("github.com/qoryai/qory-github", nil)
    {:ok, gitlab} = Source.parse("gitlab.com/acme/tools/qory-webhook", nil)
    {:ok, forgejo} = Source.parse("git.example.com/acme/shop", "forgejo")
    {:ok, url} = Source.parse("https://downloads.example.com/description.json", nil)

    assert Source.owner(github) == "github.com/qoryai"
    assert Source.owner(gitlab) == "gitlab.com/acme/tools"
    assert Source.owner(url) == "downloads.example.com"

    assert Source.public_forge?(github)
    refute Source.public_forge?(forgejo)
    refute Source.public_forge?(url)
  end
end
