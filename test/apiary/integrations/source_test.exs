defmodule Apiary.Integrations.SourceTest do
  use ExUnit.Case, async: true

  alias Apiary.Integrations.Source

  describe "a forge path" do
    test "takes its kind from its public forge's host" do
      assert {:ok,
              %Source{
                form: :forge,
                forge_kind: "github",
                host: "github.com",
                path: "qoryai/qory-github"
              }} =
               Source.parse("github.com/qoryai/qory-github")

      assert {:ok, %Source{forge_kind: "gitlab"}} =
               Source.parse("gitlab.com/acme/tools/qory-webhook")

      assert {:ok, %Source{forge_kind: "forgejo"}} = Source.parse("codeberg.org/acme/shop")
      assert Enum.sort(Source.public_forges()) == ~w(codeberg.org github.com gitlab.com)
    end

    test "is refused on any host but github.com, gitlab.com and codeberg.org" do
      for source <- [
            "git.example.com/acme/shop",
            "github.example.com/acme/shop",
            "gitlab.example.com/acme/tools/shop",
            "private.example.com/acme/shop",
            "www.github.com/acme/shop",
            "gitlab.com.example.com/acme/shop"
          ] do
        assert {:error, :forge_host_unlisted} = Source.parse(source), source
      end
    end

    test "is owner/repo on GitHub and Codeberg, any depth on GitLab" do
      assert {:error, :path_invalid} = Source.parse("github.com/acme/tools/shop")
      assert {:error, :path_invalid} = Source.parse("codeberg.org/acme/tools/shop")
      assert {:ok, _} = Source.parse("gitlab.com/acme/tools/sub/shop")
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
        assert {:error, _} = Source.parse(source), inspect(source)
      end
    end
  end

  describe "a URL source" do
    test "is an https URL of a description.json, with no kind" do
      url = "https://downloads.example.com/qory-jira/1.4.0/description.json"

      assert {:ok, %Source{form: :url, host: "downloads.example.com", forge_kind: nil}} =
               Source.parse(url)
    end

    test "is refused while the operator has them off" do
      url = "https://downloads.example.com/qory-jira/1.4.0/description.json"
      assert {:error, :url_sources_off} = Source.parse(url, url_sources: false)
      assert {:ok, %Source{form: :url}} = Source.parse(url, url_sources: true)

      assert {:ok, %Source{form: :forge}} =
               Source.parse("github.com/acme/shop", url_sources: false)
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
        assert {:error, :source_invalid} = Source.parse(url), inspect(url)
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
    {:ok, github} = Source.parse("github.com/qoryai/qory-github")
    {:ok, forgejo} = Source.parse("codeberg.org/acme/shop")
    {:ok, gitlab} = Source.parse("gitlab.com/acme/tools/qory-webhook")

    {:ok, url} =
      Source.parse("https://downloads.example.com/qory-jira/1.4.0/description.json")

    assert Source.download_url(github, "0.1.0", "description.json") ==
             "https://github.com/qoryai/qory-github/releases/download/v0.1.0/description.json"

    assert Source.download_url(forgejo, "2.1.0", "checksums.txt") ==
             "https://codeberg.org/acme/shop/releases/download/v2.1.0/checksums.txt"

    assert Source.download_url(gitlab, "1.1.0", "description.json") ==
             "https://gitlab.com/api/v4/projects/acme%2Ftools%2Fqory-webhook/releases/v1.1.0/downloads/description.json"

    assert Source.download_url(url, nil, "checksums.txt") ==
             "https://downloads.example.com/qory-jira/1.4.0/checksums.txt"
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
