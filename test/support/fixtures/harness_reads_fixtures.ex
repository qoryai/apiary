defmodule Apiary.HarnessReadsFixtures do
  @moduledoc """
  Adapters that answer Qory Apiary's calls `resolve` and `read` (`Apiary.Adapters.Calls`)
  through a `Req.Test` stub, for the tests that read harness sources through them: an
  adapter with a call address, a live grant of a connection, and the stub.
  """

  import Ecto.Query

  alias Apiary.Repo
  alias Apiary.Adapters.{Calls, Collection, Grant}
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.Nodes.Node

  @doc """
  An adapter with a call address, as its start-up declares one: `%{adapter, host, seed}`,
  the seed to sign its answers with.
  """
  def call_adapter_fixture(attrs \\ %{}) do
    %{adapter: adapter, pair: pair} = Apiary.NodesFixtures.connectable_adapter_fixture(attrs)
    host = adapter.name <> ".localhost"

    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
        set: [call_url: "https://#{host}/calls/", call_instance_id: "instance-1"]
      )

    %{adapter: Repo.get!(Node, adapter.id), host: host, seed: pair.secret}
  end

  @doc "A live grant of `connection` with `grant_ref`, of the organisation `organisation_id`."
  def live_grant_fixture(organisation_id, adapter, connection, grant_ref) do
    Repo.insert!(%Grant{
      public_id: Apiary.PublicId.generate(Grant.prefix()),
      organisation_id: organisation_id,
      adapter_id: adapter.id,
      connection_id: connection.id,
      grant_ref: grant_ref,
      state: :live,
      pass_nonce: :crypto.strong_rand_bytes(16),
      granted_at: DateTime.utc_now()
    })
  end

  @doc """
  A live collection of `connection` at `url`, titled `title`, assigned to no workspace,
  with no target.
  """
  def harness_collection_fixture(connection, url, title) do
    Repo.insert!(%Collection{
      public_id: Apiary.PublicId.generate(Collection.prefix()),
      organisation_id: connection.organisation_id,
      adapter_id: connection.adapter_id,
      connection_id: connection.id,
      external_ref: "ref-" <> title,
      url: url,
      title: title,
      last_listed_at: DateTime.utc_now(:second)
    })
  end

  @template_source Path.expand("../../fixtures/harness/v1/sources/factory", __DIR__)

  @doc """
  The `process.yaml` of the module `support-desk` of the fixture harness source
  (`test/fixtures/harness/v1/sources/factory`): a template on the stack `support`.
  """
  def support_desk_file,
    do: File.read!(Path.join(@template_source, "modules/support-desk/process.yaml"))

  @doc """
  The files, for the `files:` of `serve_calls/2`, of the harness repository whose resource
  is `resource_ref`: a root `qory.yaml` that exports the stack `support` and lists
  `modules` (a map of a module's name to its `process.yaml`, in the order of its names),
  and the file of each module. `root:` replaces the `modules` line of the root file, as
  YAML, such as `"[a, b]"`.
  """
  def repository_files(resource_ref, modules, opts \\ []) do
    names = modules |> Map.keys() |> Enum.sort()
    listed = Keyword.get(opts, :root, "[" <> Enum.join(names, ", ") <> "]")

    Map.new(modules, fn {name, file} ->
      {{resource_ref, "modules/#{name}/process.yaml"}, file}
    end)
    |> Map.put(
      {resource_ref, "qory.yaml"},
      "exports:\n  stacks: [support]\n  modules: #{listed}\n"
    )
  end

  @doc """
  Serves the calls of `adapter` for `count` connected repositories of `connection`, each
  at `https://code.example.com/acme/repo-NN`, titled `acme/repo-NN`, with one module
  `support-desk` whose file is `support_desk_file/0`. Returns the collections.
  """
  def many_repositories(adapter, connection, grant_ref, count) do
    for n <- 1..count do
      number = String.pad_leading(Integer.to_string(n), 2, "0")
      git = "https://code.example.com/acme/repo-#{number}"
      {git, harness_collection_fixture(connection, git, "acme/repo-#{number}"), "R_#{number}"}
    end
    |> then(fn repos ->
      covered =
        %{adapter.adapter.id => Map.new(repos, fn {git, _c, ref} -> {git, {grant_ref, ref}} end)}

      files =
        Enum.reduce(repos, %{}, fn {_git, _c, ref}, files ->
          Map.merge(files, repository_files(ref, %{"support-desk" => support_desk_file()}))
        end)

      serve_calls([adapter], covered: covered, files: files)
      Enum.map(repos, fn {_git, collection, _ref} -> collection end)
    end)
  end

  @doc """
  Serves the calls of `adapters`, each `%{adapter, host, seed}`. `covered` maps an
  adapter's id to a map of an address to its `{grant_ref, resource_ref}`; `files` maps
  `{resource_ref, path}` to a document. A public repository is served by its host
  (`Apiary.PublicGitServer`). A resource's version is `c-<resource_ref>`, whatever version a read asks, or its value in
  `versions`, a map by resource_ref. `refuse_at` maps a version a read asks for (`at`) to
  the code a 404 refuses that read with, such as `"version_not_found"`, and `refuse_path`
  does so for a read of a path. `down: true` makes every call reach no one, `down:` a list
  of adapter ids the calls of those adapters, and `down_path:` a list of paths the reads
  of those paths.
  Each call is sent to the test as `{:harness_call, path, members}`.
  """
  def serve_calls(adapters, opts \\ []) do
    test = self()
    hosts = Map.new(adapters, &{&1.host, &1})
    covered = Keyword.get(opts, :covered, %{})
    files = Keyword.get(opts, :files, %{})

    Req.Test.stub(Calls, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [host] = Plug.Conn.get_req_header(conn, "host")
      call = Jason.decode!(body)
      path = conn.request_path |> String.split("/") |> List.last()
      send(test, {:harness_call, path, Map.drop(call, ["version", "time"])})
      adapter = Map.fetch!(hosts, host)

      cond do
        down?(opts[:down], adapter) or call["path"] in (opts[:down_path] || []) ->
          Req.Test.transport_error(conn, :econnrefused)

        path == "resolve" ->
          by_address = Map.get(covered, adapter.adapter.id, %{})

          results =
            for address <- call["addresses"] do
              case by_address[address] do
                {grant_ref, resource_ref} ->
                  %{
                    "address" => address,
                    "grant_ref" => grant_ref,
                    "resource_ref" => resource_ref
                  }

                nil ->
                  %{"address" => address, "covered" => false}
              end
            end

          answer(conn, 200, %{"version" => 1, "revision" => 1, "results" => results}, adapter)

        path == "read" and is_map_key(opts[:refuse_at] || %{}, call["at"]) ->
          answer(conn, 404, %{"error" => opts[:refuse_at][call["at"]]}, adapter)

        path == "read" and is_map_key(opts[:refuse_path] || %{}, call["path"]) ->
          answer(conn, 404, %{"error" => opts[:refuse_path][call["path"]]}, adapter)

        path == "read" ->
          found =
            case files[{call["resource_ref"], call["path"]}] do
              nil -> %{"found" => false}
              content -> %{"content" => content}
            end

          version =
            Map.get(opts[:versions] || %{}, call["resource_ref"], "c-" <> call["resource_ref"])

          body = Map.merge(%{"version" => 1, "revision" => 1, "resolved_at" => version}, found)
          answer(conn, 200, body, adapter)
      end
    end)
  end

  defp down?(true, _adapter), do: true
  defp down?(ids, adapter) when is_list(ids), do: adapter.adapter.id in ids
  defp down?(_up, _adapter), do: false

  defp answer(conn, status, body, adapter) do
    body = Jason.encode!(body)
    [call_signature] = Plug.Conn.get_req_header(conn, "x-qory-signature-ed25519")
    message = SignedMessage.call_answer(status, call_signature, body)
    signature = Ed25519.encode(:crypto.sign(:eddsa, :none, message, [adapter.seed, :ed25519]))

    conn
    |> Plug.Conn.put_resp_header("x-qory-signature-ed25519", signature)
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end
end
