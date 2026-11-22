defmodule Apiary.ConnectionsFixtures do
  @moduledoc """
  Releases, workspaces, repositories and connections for the tests: a release is found as the
  product finds it, its files served by the `Req.Test` stub of
  `Apiary.Integrations.Fetch`.
  """

  import Apiary.DescriptionFixtures

  alias Apiary.Integrations

  @doc """
  provider_added_with_model_proxies!/3 is a model provider added for `scope` with
  `attrs`, as `Apiary.Connections.create_provider/2` takes them, while the feature
  `model_proxies` is on: a provider whose description lists no models, such as LiteLLM,
  added before the feature was turned off. `tags` is the test's context. The feature is
  on for that one call (`Apiary.DataCase.model_proxies_on!/1`, which raises for an async
  test or with `factory` off), and the features are put back after it.
  """
  def provider_added_with_model_proxies!(tags, scope, attrs) do
    previous = Apiary.DataCase.model_proxies_on!(tags)

    try do
      {:ok, provider} = Apiary.Connections.create_provider(scope, attrs)
      provider
    after
      Application.put_env(:apiary, :features, previous)
    end
  end

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

  @doc "workspace!/2 is another workspace of the scope's organisation, named `name`."
  def workspace!(scope, name),
    do: Apiary.OrganisationsFixtures.workspace_fixture(scope.organisation, name)

  @doc """
  no_runtime_hosts!/0 makes the catalogue, in this process and the processes it starts, the
  same runtimes with no `egress_hosts`: for a test of what a document has from other
  sources, compared byte for byte.
  """
  def no_runtime_hosts! do
    :ok =
      Apiary.Kinds.Runtimes.list()
      |> Enum.map(&%{&1 | egress_hosts: []})
      |> Apiary.Kinds.Runtimes.put_test_list()
  end

  @doc "target!/2 is a repository of the scope's workspace at `path`."
  def target!(scope, path) do
    Apiary.NodesFixtures.target_fixture(%{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      system: "github.example",
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end
end
