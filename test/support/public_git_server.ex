defmodule Apiary.PublicGitServer do
  @moduledoc """
  Public git repositories for the tests, served with no network: each is a repository in
  a temporary folder, and the `Req.Test` stub of `Apiary.Harnesses.PublicGit` answers
  its smart-HTTP requests by running `git upload-pack --stateless-rpc` on it, as
  `git http-backend` does: protocol version 2 for a request with `Git-Protocol:
  version=2`, else version 0.

  A request no stub answers gets a `404` (`Apiary.PublicGitStub`): a repository that is
  not public. The Qory harness's address is the exception: every test, with or without a
  stub, reads it from the fixture repository (`Apiary.QoryHarnessFixture`), unless the
  test serves that address itself.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @git_env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_AUTHOR_NAME", "Test"},
    {"GIT_AUTHOR_EMAIL", "test@example.com"},
    {"GIT_COMMITTER_NAME", "Test"},
    {"GIT_COMMITTER_EMAIL", "test@example.com"}
  ]

  @doc """
  repository!/2 is a new repository with `files`, a map of path to content, in one
  commit on `main`: `%{dir, commit}`. `opts`: `filter: false` for a host that offers no
  `filter`; `tags`, names of annotated tags at that commit; `branches`, names of more
  branches at it.
  """
  def repository!(files, opts \\ []) do
    repository = build!(files, opts)
    on_exit(fn -> File.rm_rf!(repository.dir) end)
    repository
  end

  @doc """
  build!/2 is `repository!/2` outside a test: the caller removes the folder, `dir`.
  """
  def build!(files, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "public-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["config", "uploadpack.allowAnySHA1InWant", "true"])

    if Keyword.get(opts, :filter, true),
      do: git!(dir, ["config", "uploadpack.allowFilter", "true"])

    commit = commit!(dir, files)
    for tag <- Keyword.get(opts, :tags, []), do: git!(dir, ["tag", "-a", tag, "-m", tag])
    for branch <- Keyword.get(opts, :branches, []), do: git!(dir, ["branch", branch])
    %{dir: dir, commit: commit}
  end

  @doc "commit!/2 commits `files` on top of the repository in `dir`, and is the commit's id."
  def commit!(dir, files) do
    for {path, content} <- files do
      file = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, content)
    end

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "--allow-empty", "-m", "files"])
    dir |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  @doc """
  serve/2 answers the git requests to each address of `repositories`, a map of
  `"https://host/path"` to a repository's folder, for the calling test. Every request is
  sent to the test as `{:git_request, method, host, path, headers}`. `opts`: `version:
  0` for a host that speaks only version 0; `answer`, a function of the conn that answers
  in place of git, or returns nil to let git answer.
  """
  def serve(repositories, opts \\ []) do
    test = self()

    folders = Map.merge(Apiary.QoryHarnessFixture.folders(), folders(repositories))

    Req.Test.stub(Apiary.Harnesses.PublicGit, fn conn ->
      [host] = Plug.Conn.get_req_header(conn, "host")
      host = host |> String.split(":") |> hd()
      send(test, {:git_request, conn.method, host, conn.request_path, conn.req_headers})

      case opts[:answer] && opts[:answer].(conn) do
        nil -> answer(conn, folders, host, opts)
        answered -> answered
      end
    end)
  end

  @doc """
  folders/1 is the folders of `repositories`, a map of `"https://host/path"` to a
  repository's folder, by host and path, as `serve/2` and `answer/4` take them.
  """
  def folders(repositories) do
    Map.new(repositories, fn {address, dir} ->
      uri = URI.parse(address)
      {{uri.host, String.trim_trailing(uri.path, "/")}, dir}
    end)
  end

  @doc """
  answer/4 answers a git request to a repository of `folders` (`folders/1`) at `host`,
  as `serve/2` does, else `404`.
  """
  def answer(conn, folders, host, opts) do
    version =
      if opts[:version] != 0 and
           Plug.Conn.get_req_header(conn, "git-protocol") == ["version=2"],
         do: "version=2",
         else: nil

    cond do
      conn.method == "GET" and String.ends_with?(conn.request_path, "/info/refs") ->
        case Map.get(folders, {host, String.replace_suffix(conn.request_path, "/info/refs", "")}) do
          nil -> Plug.Conn.send_resp(conn, 404, "")
          dir -> advertise(conn, dir, version)
        end

      conn.method == "POST" and String.ends_with?(conn.request_path, "/git-upload-pack") ->
        path = String.replace_suffix(conn.request_path, "/git-upload-pack", "")

        case Map.get(folders, {host, path}) do
          nil -> Plug.Conn.send_resp(conn, 404, "")
          dir -> upload_pack(conn, dir, version)
        end

      true ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp advertise(conn, dir, version) do
    {out, 0} =
      System.cmd("git", ["upload-pack", "--stateless-rpc", "--advertise-refs", dir],
        env: env(version)
      )

    # git http-backend writes the service line for version 0 alone.
    body = if version, do: out, else: "001e# service=git-upload-pack\n0000" <> out

    conn
    |> Plug.Conn.put_resp_content_type("application/x-git-upload-pack-advertisement", nil)
    |> Plug.Conn.send_resp(200, body)
  end

  defp upload_pack(conn, dir, version) do
    input = Path.join(System.tmp_dir!(), "public-git-in-#{System.unique_integer([:positive])}")
    File.write!(input, Req.Test.raw_body(conn))

    {out, _status} =
      System.cmd(
        "sh",
        ["-c", "git upload-pack --stateless-rpc \"$1\" < \"$2\"", "sh", dir, input],
        env: env(version)
      )

    File.rm(input)

    conn
    |> Plug.Conn.put_resp_content_type("application/x-git-upload-pack-result", nil)
    |> Plug.Conn.send_resp(200, out)
  end

  defp env(nil), do: @git_env
  defp env(version), do: [{"GIT_PROTOCOL", version} | @git_env]

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], env: @git_env, stderr_to_stdout: true)
    out
  end
end

defmodule Apiary.PublicGitStub do
  @moduledoc """
  PublicGitStub is the plug `Apiary.Harnesses.PublicGit`'s requests reach in the tests:
  the `Req.Test` stub of `Apiary.Harnesses.PublicGit` where the test set one
  (`Apiary.PublicGitServer.serve/2`), else the fixture repository of the Qory harness at
  its address (`Apiary.QoryHarnessFixture`), and a `404`, a repository that is not
  public, at any other.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Req.Test.call(conn, Apiary.Harnesses.PublicGit)
  rescue
    error in RuntimeError ->
      if error.message =~ ~r/cannot find mock\/stub|no mock or stub/ do
        [host] = Plug.Conn.get_req_header(conn, "host")
        host = host |> String.split(":") |> hd()

        Apiary.PublicGitServer.answer(conn, Apiary.QoryHarnessFixture.folders(), host, [])
      else
        reraise(error, __STACKTRACE__)
      end
  end
end
