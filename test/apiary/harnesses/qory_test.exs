defmodule Apiary.Harnesses.QoryTest do
  # The Qory harness, read over git from its address (`Apiary.Harnesses.Qory`): the
  # test run's fixture repository (`Apiary.QoryHarnessFixture`), or a repository a test
  # serves at that address.
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import ExUnit.CaptureLog

  alias Apiary.Artifacts.TemplateTypes
  alias Apiary.Harnesses.{Qory, QoryRefresh}
  alias Apiary.Processes
  alias Apiary.PublicGitServer
  alias Apiary.QoryHarnessFixture

  defp serve_harness!(opts \\ []), do: QoryHarnessFixture.serve!(QoryHarnessFixture.files(), opts)

  # The methods of the git requests the stub received since the last call.
  defp git_requests do
    receive do
      {:git_request, method, _host, _path, _headers} -> [method | git_requests()]
    after
      0 -> []
    end
  end

  defp flush_git_requests do
    _methods = git_requests()
    :ok
  end

  defp stored_paths(commit) do
    Repo.all(
      from f in "qory_harness_files",
        where: f.git == ^Qory.git() and f.commit == ^commit,
        select: f.path,
        order_by: f.path
    )
  end

  test "the address is QORY_HARNESS_URL's default when it is not set" do
    assert Qory.git() == "https://github.com/qoryai/harness"
  end

  describe "a read of main" do
    test "keeps the commit's files and main's commit, which the pages read" do
      commit = QoryHarnessFixture.commit()

      assert Qory.current() == commit
      assert Qory.head("main") == commit

      # The root, the template's process and each exported stack's file, kept as nothing
      # where the commit has none (the fixture has no file of `authoring`).
      assert stored_paths(commit) == [
               "modules/software-factory/process.yaml",
               "qory.yaml",
               "stacks/authoring/qory-stack.yaml",
               "stacks/core/qory-stack.yaml",
               "stacks/software/qory-stack.yaml"
             ]
    end

    test "has the software type's template, whose process passes the rules" do
      template = Qory.template(Qory.current())

      assert template.type == "qory.software"
      assert template.stack == "software"
      assert Processes.validate(template.process) == :ok
      assert TemplateTypes.check(template) == :ok
      assert Qory.texts(Qory.current()) == Map.take(template, [:name, :summary, :description])
    end

    test "keeps the stage ids that work items keep" do
      assert Enum.map(Qory.template(Qory.current()).process["stages"], &{&1["id"], &1["name"]}) ==
               [
                 {"st_r79kph11eg", "Explore"},
                 {"st_p9w5cvh311", "Shape"},
                 {"st_6ns22c4pav", "Build"},
                 {"st_m1mqbeywdg", "Verify"},
                 {"st_k9kpv17xmy", "Release"}
               ]
    end

    test "has the stacks the harness exports and the workflows each lists" do
      commit = Qory.current()

      assert Qory.stacks(commit) == ["core", "software", "authoring"]
      assert Qory.workflows(commit, "software") == ["explore-a-ticket"]
      assert Qory.workflows(commit, "core") == []
      assert Qory.workflows(commit, "missing") == []
    end

    test "a commit with no files kept has no template, stacks or workflows" do
      commit = String.duplicate("a", 40)

      assert Qory.head(commit) == nil
      assert Qory.template(commit) == nil
      assert Qory.stacks(commit) == []
      assert Qory.workflows(commit, "software") == []
      assert Qory.template(nil) == nil
    end
  end

  describe "resolve/1" do
    test "is the commit a branch is at now, read live, and keeps nothing" do
      repository = serve_harness!()
      newer = PublicGitServer.commit!(repository.dir, %{"NOTES.md" => "newer"})

      assert Qory.resolve("main") == {:ok, newer}
      assert Qory.head("main") == QoryHarnessFixture.commit()
      assert stored_paths(newer) == []
    end

    test "is a tag's commit, and a full commit id itself" do
      repository = serve_harness!(tags: ["v1.0.0"])

      assert Qory.resolve({:tag, "v1.0.0"}) == {:ok, repository.commit}
      assert Qory.resolve(repository.commit) == {:ok, repository.commit}
    end

    test "reads a branch only among the branches, and a tag only among the tags" do
      repository = serve_harness!(tags: ["same"])
      newer = PublicGitServer.commit!(repository.dir, %{"NOTES.md" => "newer"})
      {_out, 0} = System.cmd("git", ["-C", repository.dir, "branch", "same", newer])

      assert Qory.resolve({:tag, "same"}) == {:ok, repository.commit}
      assert Qory.resolve({:branch, "same"}) == {:ok, newer}
      assert Qory.resolve({:tag, "main"}) == {:error, {:ref_missing, "main"}}
      assert Qory.resolve({:branch, "same-tag-only"}) == {:error, {:ref_missing, "same-tag-only"}}
    end

    test "a ref the repository does not have is ref_missing" do
      serve_harness!()

      assert Qory.resolve("no-such-branch") == {:error, {:ref_missing, "no-such-branch"}}
      assert Qory.read("no-such-branch") == {:error, {:ref_missing, "no-such-branch"}}
    end

    test "a host that fails is unreadable, with the cause and the hop" do
      PublicGitServer.serve(%{}, answer: fn conn -> Plug.Conn.send_resp(conn, 429, "") end)

      assert {:error, {:unreadable, :rate_limited, {"github.com", 443}}} = Qory.resolve("main")
      assert {:error, {:unreadable, :rate_limited, _hop}} = Qory.read("main")
    end
  end

  describe "read/1" do
    test "of a tag keeps the tag's commit and its files" do
      repository = serve_harness!(tags: ["v1.0.0"])

      assert Qory.read({:tag, "v1.0.0"}) == {:ok, repository.commit}
      assert Qory.head({:tag, "v1.0.0"}) == repository.commit
      assert Qory.head({:branch, "v1.0.0"}) == nil
      assert Qory.template(repository.commit).type == "qory.software"
    end

    test "of a commit keeps its files, and the head of the commit is the commit" do
      repository = serve_harness!()
      newer = PublicGitServer.commit!(repository.dir, %{"NOTES.md" => "newer"})

      assert Qory.read(newer) == {:ok, newer}
      assert Qory.head(newer) == newer
      assert Qory.head("main") == QoryHarnessFixture.commit()
      assert Qory.workflows(newer, "software") == ["explore-a-ticket"]
    end

    test "leaves out a stack whose name is not one path segment, keeps the rest, and logs it" do
      root =
        String.replace(
          QoryHarnessFixture.files()["qory.yaml"],
          "stacks: [core, software, authoring]",
          ~s(stacks: [core, "../escape", software, "a/b"])
        )

      repository =
        QoryHarnessFixture.serve!(Map.put(QoryHarnessFixture.files(), "qory.yaml", root))

      newer = PublicGitServer.commit!(repository.dir, %{"NOTES.md" => "newer"})

      log = capture_log(fn -> assert Qory.read(newer) == {:ok, newer} end)

      assert Qory.stacks(newer) == ["core", "software"]
      assert Qory.workflows(newer, "software") == ["explore-a-ticket"]
      assert log =~ ~s(not_one_segment=["../escape", "a/b"])
      refute Enum.any?(stored_paths(newer), &String.contains?(&1, ".."))
    end

    test "of files that break the harness format keeps nothing" do
      repository = PublicGitServer.repository!(%{"README.md" => "no harness"})
      PublicGitServer.serve(%{Qory.git() => repository.dir})

      assert Qory.read("main") == {:error, {:unreadable, :invalid, nil}}
      assert stored_paths(repository.commit) == []
      assert Qory.current() == QoryHarnessFixture.commit()
    end
  end

  describe "the budget of a read" do
    test "gives each request the time left, and no more requests than its count" do
      budget = Qory.budget(60_000, 2)

      assert {:ok, ms} = budget.()
      assert ms <= Apiary.Harnesses.PublicGit.request_seconds() * 1000
      assert {:ok, _ms} = budget.()
      assert budget.() == {:error, :no_calls}
    end

    test "is late once its time has run out" do
      budget = Qory.budget(1, 10)
      Process.sleep(5)

      assert budget.() == {:error, :late}
    end
  end

  describe "the refresh job" do
    test "reads main's newest commit, which the pages then read" do
      repository = serve_harness!()
      newer = PublicGitServer.commit!(repository.dir, %{"NOTES.md" => "newer"})

      assert perform_job(QoryRefresh, %{}) == :ok
      assert Qory.current() == newer
    end

    test "is enqueued once when the application starts, and not again while one waits" do
      # Only the boot reads this setting, which the tests turn off (config/test.exs).
      Application.put_env(:apiary, QoryRefresh, at_boot: true)
      on_exit(fn -> Application.put_env(:apiary, QoryRefresh, at_boot: false) end)

      assert QoryRefresh.enqueue_at_boot() == :ok
      assert QoryRefresh.enqueue_at_boot() == :ok
      assert [_job] = all_enqueued(worker: QoryRefresh)
    end

    @tag needs: :factory
    test "reads each branch a choice of the Qory harness follows, and no tag" do
      repository = serve_harness!(branches: ["next"], tags: ["v1.0.0"])
      newer = PublicGitServer.commit!(repository.dir, %{"NOTES.md" => "newer"})
      %{scope: scope} = Apiary.OrganisationsFixtures.sign_up_fixture()
      %{scope: other} = Apiary.OrganisationsFixtures.sign_up_fixture()

      {:ok, _row} = Apiary.Stacks.Sources.choose(scope, {:qory, {:branch, "next"}})
      {:ok, _row} = Apiary.Stacks.Sources.choose(other, {:qory, {:tag, "v1.0.0"}})
      {_out, 0} = System.cmd("git", ["-C", repository.dir, "branch", "-f", "next", newer])

      assert perform_job(QoryRefresh, %{}) == :ok
      assert Qory.head({:branch, "next"}) == newer
      assert Qory.head({:branch, "main"}) == newer
      assert Qory.head({:tag, "v1.0.0"}) == repository.commit
    end

    @tag needs: :factory
    test "reads once each tag and commit a choice has whose files are not kept at the address" do
      repository = serve_harness!(tags: ["v1.0.0"])
      newer = PublicGitServer.commit!(repository.dir, %{"NOTES.md" => "newer"})
      _newest = PublicGitServer.commit!(repository.dir, %{"NOTES.md" => "newest"})
      %{scope: scope} = Apiary.OrganisationsFixtures.sign_up_fixture()
      %{scope: other} = Apiary.OrganisationsFixtures.sign_up_fixture()

      {:ok, _row} = Apiary.Stacks.Sources.choose(scope, {:qory, {:tag, "v1.0.0"}})
      {:ok, _row} = Apiary.Stacks.Sources.choose(other, {:qory, {:commit, newer}})

      # The address changed: nothing of the tag or the commit is kept at the new one.
      {_count, _rows} =
        Repo.delete_all(from h in "qory_harness_heads", where: h.ref == "refs/tags/v1.0.0")

      {_count, _rows} = Repo.delete_all(from f in "qory_harness_files", where: f.commit == ^newer)
      assert Qory.head({:tag, "v1.0.0"}) == nil
      assert Qory.head({:commit, newer}) == nil

      assert perform_job(QoryRefresh, %{}) == :ok
      assert Qory.head({:tag, "v1.0.0"}) == repository.commit
      assert Qory.head({:commit, newer}) == newer

      # Kept now: the next refresh reads main's ref alone.
      flush_git_requests()
      assert perform_job(QoryRefresh, %{}) == :ok
      assert Enum.count(git_requests(), &(&1 == "GET")) == 1
    end

    test "a read that fails is one line in the log, and the pages keep the last commit" do
      PublicGitServer.serve(%{}, answer: fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      log = capture_log(fn -> assert perform_job(QoryRefresh, %{}) == :ok end)

      assert log =~ "the Qory harness could not be read"
      assert Qory.current() == QoryHarnessFixture.commit()
    end
  end

  describe "the cause of a failed read" do
    test "is kept as a map and read back" do
      for cause <- [
            {:unreachable, 10},
            :rate_limited,
            :server_error,
            :not_found,
            :too_large,
            :invalid
          ] do
        assert cause |> Qory.cause_value() |> Qory.cause_of() == cause
      end

      assert Qory.cause_of(nil) == :failed
      assert Qory.cause_words({:unreachable, 10}) == "the connection timed out after 10 seconds"

      assert Qory.cause_words(:server_error) ==
               "the harness host returned a server error (HTTP 500)"
    end
  end
end
