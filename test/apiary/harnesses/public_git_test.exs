defmodule Apiary.Harnesses.PublicGitTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Apiary.Harnesses.PublicGit
  alias Apiary.PublicGitServer

  @git "https://github.com/acme/harness"

  # A repository with a unique file, so no other test's cache entry matches its commit.
  defp repository!(files \\ %{}, opts \\ []) do
    files =
      Map.merge(
        %{
          "harness.yaml" => "name: #{System.unique_integer([:positive])}\n",
          "stacks/web/qory-stack.yaml" => "modules: []\n"
        },
        files
      )

    PublicGitServer.repository!(files, opts)
  end

  defp requests do
    receive do
      {:git_request, method, host, path, headers} ->
        [{method, host, path, Map.new(headers)} | requests()]
    after
      0 -> []
    end
  end

  defp read(git \\ @git, at, path),
    do: PublicGit.session(&PublicGit.no_budget/0, fn -> PublicGit.read(git, at, path) end)

  describe "version 2, with filter" do
    test "reads a file at HEAD: the advertisement, ls-refs, the trees, then the file by its id" do
      repo = repository!()
      PublicGitServer.serve(%{@git => repo.dir})

      assert {:ok, "name: " <> _, commit} = read("HEAD", "harness.yaml")
      assert commit == repo.commit

      assert [
               {"GET", "github.com", "/acme/harness/info/refs", get},
               {"POST", "github.com", "/acme/harness/git-upload-pack", _ls_refs},
               {"POST", "github.com", "/acme/harness/git-upload-pack", _trees},
               {"POST", "github.com", "/acme/harness/git-upload-pack", post}
             ] = requests()

      assert get["git-protocol"] == "version=2"
      assert get["user-agent"] == "git/2.0 (qory-apiary)"
      assert post["content-type"] == "application/x-git-upload-pack-request"

      for headers <- [get, post] do
        assert headers |> Map.keys() |> Enum.sort() ==
                 Enum.sort(
                   ["host", "user-agent", "git-protocol"] ++
                     if(headers == post, do: ["content-type", "accept"], else: [])
                 )
      end
    end

    test "reads a nested file, and nil for a file, a folder or a folder's file that is not there" do
      repo = repository!()
      PublicGitServer.serve(%{@git => repo.dir})

      PublicGit.session(&PublicGit.no_budget/0, fn ->
        assert {:ok, "modules: []\n", _} =
                 PublicGit.read(@git, "main", "stacks/web/qory-stack.yaml")

        assert {:ok, nil, _} = PublicGit.read(@git, "main", "qory.yaml")
        assert {:ok, nil, _} = PublicGit.read(@git, "main", "stacks/web")
        assert {:ok, nil, _} = PublicGit.read(@git, "main", "stacks/api/qory-stack.yaml")
        assert {:ok, nil, _} = PublicGit.read(@git, "main", "harness.yaml/qory-stack.yaml")
      end)

      # One advertisement, one ref list and one trees' fetch in the session.
      gets = for {"GET", _, _, _} = r <- requests(), do: r
      assert length(gets) == 1
    end

    test "a tag before a branch of the same name, peeled; refs/heads/<name> as written; a commit as it is" do
      repo = repository!(%{}, tags: ["main"])
      later = PublicGitServer.commit!(repo.dir, %{"harness.yaml" => "name: later\n"})
      PublicGitServer.serve(%{@git => repo.dir})

      assert {:ok, _, tagged} = read("main", "harness.yaml")
      assert tagged == repo.commit
      assert {:ok, "name: later\n", ^later} = read("refs/heads/main", "harness.yaml")
      assert {:ok, "name: later\n", ^later} = read("HEAD", "harness.yaml")
      requests()

      assert {:ok, _, ^tagged} = read(repo.commit, "harness.yaml")
      # A commit id needs no ref list.
      assert length(for {"POST", _, _, _} = r <- requests(), do: r) <= 2
    end

    test "a ref or commit the host does not have is a version not found" do
      repo = repository!()
      PublicGitServer.serve(%{@git => repo.dir})

      assert read("nope", "harness.yaml") == {:error, :version_not_found}
      assert read("refs/tags/nope", "harness.yaml") == {:error, :version_not_found}
      assert read(String.duplicate("a", 40), "harness.yaml") == {:error, :version_not_found}
      assert read(String.duplicate("a", 64), "harness.yaml") == {:error, :version_not_found}
    end

    test "a file over 256 KiB is too large, and one that is not text is not text" do
      repo =
        repository!(%{
          "big.yaml" => String.duplicate("a", PublicGit.file_bytes() + 1),
          "bin.yaml" => <<0, 1, 2>>,
          "latin.yaml" => <<0xE9>>
        })

      PublicGitServer.serve(%{@git => repo.dir})

      assert read("main", "big.yaml") == {:error, :too_large}
      assert read("main", "bin.yaml") == {:error, :not_text}
      assert read("main", "latin.yaml") == {:error, :not_text}
    end

    test "a path with an empty, . or .. part is refused before any request" do
      for path <- ["../harness.yaml", "a//b", "./harness.yaml", "stacks/.."] do
        assert read("main", path) == {:error, :failed}
      end

      assert requests() == []
    end
  end

  describe "other hosts" do
    test "a host without filter gets one fetch of the whole commit" do
      repo = repository!(%{}, filter: false)
      PublicGitServer.serve(%{@git => repo.dir})

      PublicGit.session(&PublicGit.no_budget/0, fn ->
        assert {:ok, "name: " <> _, _} = PublicGit.read(@git, "main", "harness.yaml")

        assert {:ok, "modules: []\n", _} =
                 PublicGit.read(@git, "main", "stacks/web/qory-stack.yaml")
      end)

      assert [{"GET", _, _, _}, {"POST", _, _, _}, {"POST", _, _, _}] = requests()
    end

    test "a host that speaks only version 0 is read from its ref list, with one fetch" do
      repo = repository!(%{}, tags: ["v1"])
      PublicGitServer.serve(%{@git => repo.dir}, version: 0)

      PublicGit.session(&PublicGit.no_budget/0, fn ->
        assert {:ok, "name: " <> _, commit} = PublicGit.read(@git, "v1", "harness.yaml")
        assert commit == repo.commit
        assert {:ok, nil, ^commit} = PublicGit.read(@git, "HEAD", "qory.yaml")
      end)

      assert [{"GET", _, _, _}, {"POST", _, _, _}] = requests()
    end

    test "an address with a port keeps it in the Host header" do
      repo = repository!()
      git = "https://git.example.com:8443/team/harness"
      PublicGitServer.serve(%{"https://git.example.com/team/harness" => repo.dir})

      assert {:ok, _, _} = read(git, "main", "harness.yaml")
      assert [{"GET", "git.example.com", _, %{"host" => "git.example.com:8443"}} | _] = requests()
    end
  end

  describe "failures" do
    test "a repository the host does not serve is not found" do
      assert read("HEAD", "harness.yaml") == {:error, :not_found}
    end

    test "a host that resolves to a private or loopback address is not allowed, and gets no request" do
      capture_log(fn ->
        assert read("https://private.example.com/a/b", "HEAD", "harness.yaml") ==
                 {:error, :not_allowed}

        assert read("https://loopback.example.com/a/b", "HEAD", "harness.yaml") ==
                 {:error, :not_allowed}
      end)

      assert requests() == []
    end

    test "a host that resolves to no address is unreachable, with the request's seconds" do
      capture_log(fn ->
        assert read("https://nowhere.example.com/a/b", "HEAD", "harness.yaml") ==
                 {:error, {:unreachable, 10}}
      end)
    end

    test "an answer that is no ref advertisement failed" do
      PublicGitServer.serve(%{},
        answer: fn conn ->
          conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, "x")
        end
      )

      capture_log(fn -> assert read("HEAD", "harness.yaml") == {:error, :failed} end)
    end

    test "the first request follows a redirect, checked again, and the later ones go where it ended" do
      repo = repository!()

      PublicGitServer.serve(%{"https://mirror.example.com/acme/harness" => repo.dir},
        answer: fn conn ->
          if Plug.Conn.get_req_header(conn, "host") == ["github.com"] do
            conn
            |> Plug.Conn.put_resp_header(
              "location",
              "https://mirror.example.com/acme/harness/info/refs?service=git-upload-pack"
            )
            |> Plug.Conn.send_resp(301, "")
          end
        end
      )

      assert {:ok, "name: " <> _, _} = read("HEAD", "harness.yaml")

      assert [{"GET", "github.com", _, _}, {"GET", "mirror.example.com", _, _} | posts] =
               requests()

      assert Enum.all?(posts, &match?({"POST", "mirror.example.com", _, _}, &1))
    end

    test "a redirect to a private address is not allowed" do
      PublicGitServer.serve(%{},
        answer: fn conn ->
          conn
          |> Plug.Conn.put_resp_header(
            "location",
            "https://private.example.com/x/info/refs?service=git-upload-pack"
          )
          |> Plug.Conn.send_resp(302, "")
        end
      )

      capture_log(fn -> assert read("HEAD", "harness.yaml") == {:error, :not_allowed} end)
    end

    test "a redirect of a POST is not followed" do
      repo = repository!()

      PublicGitServer.serve(%{@git => repo.dir},
        answer: fn conn ->
          if conn.method == "POST" do
            conn
            |> Plug.Conn.put_resp_header("location", "https://github.com/other/git-upload-pack")
            |> Plug.Conn.send_resp(307, "")
          end
        end
      )

      capture_log(fn -> assert read("HEAD", "harness.yaml") == {:error, :failed} end)

      assert [{"GET", _, _, _}, {"POST", "github.com", "/acme/harness/git-upload-pack", _}] =
               requests()
    end

    test "a redirect that changes the service part failed" do
      PublicGitServer.serve(%{},
        answer: fn conn ->
          if Plug.Conn.get_req_header(conn, "host") == ["github.com"] do
            conn
            |> Plug.Conn.put_resp_header("location", "https://mirror.example.com/other")
            |> Plug.Conn.send_resp(302, "")
          else
            conn
            |> Plug.Conn.put_resp_content_type("application/x-git-upload-pack-advertisement", nil)
            |> Plug.Conn.send_resp(200, "000eversion 2\n0000")
          end
        end
      )

      assert read("HEAD", "harness.yaml") == {:error, :failed}
    end

    test "a request past the session's budget is late, and makes no request" do
      repo = repository!()
      PublicGitServer.serve(%{@git => repo.dir})

      assert PublicGit.session(fn -> {:error, :late} end, fn ->
               PublicGit.read(@git, "HEAD", "harness.yaml")
             end) ==
               {:error, :late}

      assert requests() == []
    end

    test "each request takes its time from the session's budget, at most 10 seconds" do
      repo = repository!()
      PublicGitServer.serve(%{@git => repo.dir})
      counter = :counters.new(1, [])

      budget = fn ->
        :counters.add(counter, 1, 1)
        {:ok, 60_000}
      end

      assert {:ok, _, _} =
               PublicGit.session(budget, fn -> PublicGit.read(@git, "HEAD", "harness.yaml") end)

      assert :counters.get(counter, 1) == length(requests())
    end
  end

  describe "the cache" do
    test "a file read at a commit is read again from the cache, after the advertisement and the ref" do
      repo = repository!()
      PublicGitServer.serve(%{@git => repo.dir})

      assert {:ok, content, commit} = read("main", "harness.yaml")
      requests()

      assert {:ok, ^content, ^commit} = read("main", "harness.yaml")
      # The advertisement and the ref list only.
      assert [{"GET", _, _, _}, {"POST", _, _, _}] = requests()

      assert {:ok, ^content, ^commit} = read(commit, "harness.yaml")
      assert [{"GET", _, _, _}] = requests()
    end

    test "a repository that is no longer public is not read from the cache" do
      repo = repository!()
      PublicGitServer.serve(%{@git => repo.dir})
      assert {:ok, _content, commit} = read("main", "harness.yaml")

      PublicGitServer.serve(%{})
      assert read(commit, "harness.yaml") == {:error, :not_found}
    end
  end
end
