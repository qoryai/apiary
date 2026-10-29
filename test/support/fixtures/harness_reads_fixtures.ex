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

  @doc """
  Serves the calls of `adapters`, each `%{adapter, host, seed}`. `covered` maps an
  adapter's id to a map of an address to its `{grant_ref, resource_ref}`, to those and its
  public ref, `{grant_ref, resource_ref, {:public, public_ref}}`, or to its public ref
  alone, `{:public, public_ref}`, whose resource_ref is `N_<public_ref>`; `files` maps
  `{resource_ref, path}` to a document, a public ref's read as public (`read-public`). A
  resource's version is `c-<resource_ref>`, whatever version a read asks, or its value in
  `versions`, a map by resource_ref. `refuse_at` maps a version a read asks for (`at`) to
  the code a 404 refuses that read with, such as `"version_not_found"`. `down: true` makes
  every call reach no one, and `down:` a list of adapter ids the calls of those adapters.
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
        down?(opts[:down], adapter) ->
          Req.Test.transport_error(conn, :econnrefused)

        path == "resolve" ->
          by_address = Map.get(covered, adapter.adapter.id, %{})

          results =
            for address <- call["addresses"] do
              case by_address[address] do
                {:public, public_ref} ->
                  %{
                    "address" => address,
                    "resource_ref" => "N_" <> public_ref,
                    "public" => true,
                    "public_ref" => public_ref
                  }

                {grant_ref, resource_ref, {:public, public_ref}} ->
                  %{
                    "address" => address,
                    "grant_ref" => grant_ref,
                    "resource_ref" => resource_ref,
                    "public" => true,
                    "public_ref" => public_ref
                  }

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

        path in ["read", "read-public"] and is_map_key(opts[:refuse_at] || %{}, call["at"]) ->
          answer(conn, 404, %{"error" => opts[:refuse_at][call["at"]]}, adapter)

        path in ["read", "read-public"] ->
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
