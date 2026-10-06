defmodule Apiary.IntegrationsTest do
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.DescriptionFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.Integrations
  alias Apiary.Integrations.{FetchJob, Release, Source}
  alias Apiary.Audit.Entry

  @moduletag needs: :security

  @github %{source: "github.com/qoryai/qory-github", version: "0.1.0"}
  @base "/qoryai/qory-github/releases/download/v0.1.0/"

  setup do
    owner = sign_up_fixture()
    %{scope: owner.scope}
  end

  # The release's files as a forge serves them, every other path a 404, each request told
  # to the test with its Host and Authorization headers.
  defp serve(files) do
    test = self()

    Req.Test.stub(Apiary.Integrations.Fetch, fn conn ->
      send(
        test,
        {:request, Plug.Conn.get_req_header(conn, "host"),
         Plug.Conn.get_req_header(conn, "authorization"), conn.request_path}
      )

      case Map.fetch(files, conn.request_path) do
        {:ok, body} -> Plug.Conn.send_resp(conn, 200, body)
        :error -> Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  defp serve_release(description, base \\ @base) do
    bytes = encode(description)
    serve(%{(base <> "description.json") => bytes, (base <> "checksums.txt") => checksums(bytes)})
    bytes
  end

  defp fetch!(scope, release) do
    assert :ok =
             perform_job(
               FetchJob,
               FetchJob.for_scope(scope, %{"release_id" => release.id}).changes.args
             )

    {:ok, release} = Integrations.get_release(scope, release.id)
    release
  end

  describe "a request" do
    test "records a pending release, enqueues its fetch and leaves an entry", %{scope: scope} do
      assert {:ok,
              %Release{state: "pending", forge_kind: "github", requested_version: "0.1.0"} =
                release} =
               Integrations.request_release(scope, @github)

      assert_enqueued(worker: FetchJob, args: %{"release_id" => release.id})

      assert [%Entry{action: "connection.write", details: %{"change" => "release_requested"}}] =
               Repo.all(from e in Entry, where: e.subject_id == ^release.id)
    end

    test "refuses a source, a kind or a version the contract refuses", %{scope: scope} do
      assert {:error, changeset} =
               Integrations.request_release(scope, %{source: "github.com/acme", version: "1.0.0"})

      assert %{source: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               Integrations.request_release(scope, Map.put(@github, :forge_kind, "gitlab"))

      assert %{forge_kind: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               Integrations.request_release(scope, %{@github | version: "01.0.0"})

      assert %{version: [_]} = errors_on(changeset)

      url = "https://downloads.example.com/description.json"

      assert {:error, changeset} =
               Integrations.request_release(scope, %{source: url, version: "1.0.0"})

      assert %{version: [_]} = errors_on(changeset)
    end

    test "refuses a forge path on a host neither public nor listed", %{scope: scope} do
      for forge_kind <- [nil, "forgejo"] do
        assert {:error, changeset} =
                 Integrations.request_release(scope, %{
                   source: "git.example.com/acme/shop",
                   forge_kind: forge_kind,
                   version: "1.0.0"
                 })

        assert errors_on(changeset) == %{
                 source: ["is not on a forge this instance adds integrations from"]
               }
      end

      assert Repo.all(Release) == []
    end

    test "is a member's no more than a change is", %{scope: scope} do
      %{scope: member} = member_fixture(scope)
      assert Integrations.request_release(member, @github) == {:error, :forbidden}
    end
  end

  describe "the fetch" do
    test "reads the description, checks it against checksums.txt and records it ready",
         %{scope: scope} do
      bytes = serve_release(github_description())
      {:ok, release} = Integrations.request_release(scope, @github)

      release = fetch!(scope, release)
      assert release.state == "ready"
      assert release.description == bytes
      assert release.name == "github"
      assert release.version == "0.1.0"
      assert release.publisher_name == "Qory"
      assert release.publisher_url == "https://qory.dev"

      assert release.description_sha256 ==
               :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

      assert {:ok, %{name: "github"}} = Integrations.description(release)
    end

    test "a ready release is given back for the same source and version", %{scope: scope} do
      serve_release(github_description())
      {:ok, release} = Integrations.request_release(scope, @github)
      release = fetch!(scope, release)

      assert {:ok, %Release{id: id}} = Integrations.request_release(scope, @github)
      assert id == release.id
    end

    test "fails with one code for any failure to fetch, the reason only in the log", %{
      scope: scope
    } do
      serve(%{})
      {:ok, release} = Integrations.request_release(scope, @github)

      log =
        capture_log(fn ->
          assert %Release{state: "failed", failure: "fetch_failed"} = fetch!(scope, release)
        end)

      assert log =~ "{:status, 404}"
    end

    test "is integration_source_mismatch when checksums.txt does not vouch for the description",
         %{scope: scope} do
      bytes = encode(github_description())

      serve(%{
        (@base <> "description.json") => bytes,
        (@base <> "checksums.txt") => checksums("other")
      })

      {:ok, release} = Integrations.request_release(scope, @github)

      capture_log(fn ->
        assert %Release{state: "failed", failure: "integration_source_mismatch"} =
                 fetch!(scope, release)
      end)
    end

    test "is integration_source_mismatch when the description is of another version", %{
      scope: scope
    } do
      serve_release(github_description(%{"program_version" => "0.2.0"}))
      {:ok, release} = Integrations.request_release(scope, @github)

      capture_log(fn ->
        assert %Release{state: "failed", failure: "integration_source_mismatch"} =
                 fetch!(scope, release)
      end)
    end

    test "is integration_source_mismatch when a URL's release changed under its version",
         %{scope: scope} do
      url = "https://downloads.example.com/qory-github/description.json"
      serve_release(github_description(), "/qory-github/")
      {:ok, first} = Integrations.request_release(scope, %{source: url})
      assert %Release{state: "ready", version: "0.1.0"} = fetch!(scope, first)

      serve_release(github_description(%{"title" => "GitHub, changed"}), "/qory-github/")
      {:ok, second} = Integrations.request_release(scope, %{source: url})

      capture_log(fn ->
        assert %Release{state: "failed", failure: "integration_source_mismatch"} =
                 fetch!(scope, second)
      end)
    end

    test "is description_invalid for a description without a publisher", %{scope: scope} do
      serve_release(Map.delete(github_description(), "publisher"))
      {:ok, release} = Integrations.request_release(scope, @github)

      capture_log(fn ->
        assert %Release{failure: "description_invalid"} = fetch!(scope, release)
      end)
    end

    test "records a publisher without a URL as nil", %{scope: scope} do
      serve_release(github_description(%{"publisher" => %{"name" => "Acme"}}))
      {:ok, release} = Integrations.request_release(scope, @github)
      assert %Release{publisher_name: "Acme", publisher_url: nil} = fetch!(scope, release)
    end

    test "is description_invalid, or placeholder_conflict, as the description says", %{
      scope: scope
    } do
      serve_release(github_description(%{"name" => "Not A Name"}))
      {:ok, release} = Integrations.request_release(scope, @github)

      capture_log(fn ->
        assert %Release{failure: "description_invalid"} = fetch!(scope, release)
      end)

      conflicting =
        tracker_description(%{"program_version" => "0.1.0"})
        |> put_in(["roles", "tool", "placeholders"], ["QORY_TOKEN"])

      serve_release(conflicting)
      {:ok, release} = Integrations.request_release(scope, %{@github | version: "0.1.0"})

      capture_log(fn ->
        assert %Release{failure: "placeholder_conflict"} = fetch!(scope, release)
      end)
    end

    test "reaches no private address", %{scope: scope} do
      serve_release(github_description(), "/acme/shop/")

      {:ok, release} =
        Integrations.request_release(scope, %{
          source: "https://private.example.com/acme/shop/description.json"
        })

      log =
        capture_log(fn -> assert %Release{failure: "fetch_failed"} = fetch!(scope, release) end)

      assert log =~ "address_refused"
    end

    test "sends the token the edition gives for a forge source to the forge", %{scope: scope} do
      serve_release(github_description())
      {:ok, release} = Integrations.request_release(scope, @github)
      test = self()

      release_token = fn _scope, source ->
        send(test, {:asked, source})
        "forge-token"
      end

      assert {:ok, %Release{state: "ready"}} =
               Integrations.fetch_release(scope, release.id, release_token: release_token)

      assert_received {:asked, %Source{host: "github.com", forge_kind: "github"}}

      assert_received {:request, ["github.com"], ["Bearer forge-token"],
                       @base <> "description.json"}

      assert_received {:request, ["github.com"], ["Bearer forge-token"], @base <> "checksums.txt"}
    end

    test "fetches a URL source without a token, the edition not asked", %{scope: scope} do
      serve_release(github_description(), "/qoryai/qory-github/releases/download/v0.1.0/")
      url = "https://github.com/qoryai/qory-github/releases/download/v0.1.0/description.json"
      {:ok, release} = Integrations.request_release(scope, %{source: url})
      test = self()

      release_token = fn _scope, source ->
        send(test, {:asked, source})
        "forge-token"
      end

      assert {:ok, %Release{state: "ready"}} =
               Integrations.fetch_release(scope, release.id, release_token: release_token)

      refute_received {:asked, _source}
      assert_received {:request, ["github.com"], [], _path}
      assert_received {:request, ["github.com"], [], _path}
    end

    test "a release changed in the database is not found", %{scope: scope} do
      serve_release(github_description())
      {:ok, release} = Integrations.request_release(scope, @github)
      release = fetch!(scope, release)

      Repo.update_all(from(r in Release, where: r.id == ^release.id), set: [name: "other"])

      capture_log(fn ->
        assert Integrations.get_release(scope, release.id) == {:error, :not_found}
      end)

      Repo.update_all(from(r in Release, where: r.id == ^release.id),
        set: [name: "github", description: encode(github_description(%{"title" => "Changed"}))]
      )

      capture_log(fn ->
        assert Integrations.get_release(scope, release.id) == {:error, :not_found}
      end)
    end
  end

  test "another organisation's release is out of reach", %{scope: scope} do
    {:ok, release} = Integrations.request_release(scope, @github)
    other = sign_up_fixture().scope
    assert Integrations.get_release(other, release.id) == {:error, :not_found}
    assert Integrations.fetch_release(other, release.id) == {:error, :not_found}
  end

  test "checksum/2 reads sha256sum's format" do
    hash = String.duplicate("a", 64)
    assert Integrations.checksum("#{hash}  description.json\n", "description.json") == hash

    assert Integrations.checksum(
             "#{String.upcase(hash)} *description.json\r\n",
             "description.json"
           ) == hash

    assert Integrations.checksum("#{hash}  other.json\n", "description.json") == nil
  end
end
