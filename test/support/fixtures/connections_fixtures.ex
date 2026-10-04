defmodule Apiary.ConnectionsFixtures do
  @moduledoc """
  Releases, repositories and connections for the tests: a release is found as the
  product finds it, its files served by the `Req.Test` stub of
  `Apiary.Integrations.Fetch`.
  """

  import Apiary.DescriptionFixtures

  alias Apiary.{Integrations, Repo}
  alias Apiary.Runs.Target

  @doc """
  ready_release!/3 is a ready release of `description` (decoded), found for `scope` at
  `source`, a GitHub repository.
  """
  def ready_release!(scope, description, source \\ "github.com/qoryai/qory-github") do
    version = description["program_version"]
    bytes = encode(description)
    [_host, path] = String.split(source, "/", parts: 2)
    base = "/#{path}/releases/download/v#{version}/"

    Req.Test.stub(Apiary.Integrations.Fetch, fn conn ->
      case conn.request_path do
        path when path == base <> "description.json" ->
          Plug.Conn.send_resp(conn, 200, bytes)

        path when path == base <> "checksums.txt" ->
          Plug.Conn.send_resp(conn, 200, checksums(bytes))

        _ ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    {:ok, release} = Integrations.request_release(scope, %{source: source, version: version})
    {:ok, %{state: "ready"} = release} = Integrations.fetch_release(scope, release.id)
    release
  end

  @doc "target!/2 is a repository of the scope's workspace at `path`."
  def target!(scope, path) do
    Repo.insert!(%Target{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      system: "github.example",
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end
end
