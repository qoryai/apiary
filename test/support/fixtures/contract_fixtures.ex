defmodule Apiary.ContractFixtures do
  @moduledoc """
  Test helpers for the receiving side of the server contract: events as they
  are on the wire, requests signed as a runner signs them under a node's access key, a
  check of the server's signed answers, the contract's fixture keys held as a receiver
  under test holds them, where the runner's contract directory is, and its fixtures: the
  Ed25519 keys, known answers, signed requests and enrolments.
  """

  import Plug.Conn, only: [put_req_header: 3, get_req_header: 2, get_resp_header: 2]

  alias Apiary.{AccessKeys, Repo, SigningKey}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Contract.{Ed25519, SignedMessage}

  @content_type "application/cloudevents-batch+json"
  @published_key_id "ak_f1xt0re000000000"
  @published_secret "fixture-secret-not-a-real-one"
  @instance_id "i_gYKDhIWGh4iJiouMjY6PkA"
  @sibling "../../runner/main"
  @contract "contracts/runner/v1"

  def content_type, do: @content_type
  def published_key_id, do: @published_key_id
  def published_secret, do: @published_secret

  @doc "The instance id the signing helpers claim unless told otherwise: the contract's fixture instance."
  def instance_id, do: @instance_id

  @doc """
  A node's access key that signs requests as a runner does: a node of the scope's
  workspace (`attrs` `:node`, else a new node, kind `node`), with a key pasted on it, so
  approved. Returns `%{access_key: key, secret: seed, node: node}`: the key as a verified
  request carries it (`Apiary.AccessKeys.fetch_for_verification/1`, with its workspace
  and node), and its raw 32-byte seed, which `signed_post/5` and `signed_get/5` sign with.
  """
  def contract_key_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    node = Map.get_lazy(attrs, :node, fn -> Apiary.NodesFixtures.node_fixture(scope) end)
    %{access_key: key, pair: pair} = Apiary.AccessKeysFixtures.node_key_fixture(scope, node)
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)
    %{access_key: key, secret: pair.secret, node: key.node}
  end

  @doc """
  The contract's fixture access key `name` of `known-answers/keys.json` (`"access_key"`,
  approved, or `"pending_access_key"`, awaiting approval), held under its published id on
  `node`, as a receiver under test holds it. Written straight into the table, past the key
  checks, which refuse every fixture key: test support only.
  """
  def fixture_access_key!(%Scope{user: user}, node, name)
      when name in ~w(access_key pending_access_key) do
    entry = Map.fetch!(known_answers!("keys"), name)
    %{public_key: public_key} = fixture_key!(name)
    now = DateTime.utc_now()
    approved? = name == "access_key"

    %AccessKey{
      id: Ecto.UUID.generate(),
      organisation_id: node.organisation_id,
      workspace_id: node.workspace_id,
      node_id: node.id,
      key_id: Map.fetch!(entry, "access_key_id"),
      public_key: public_key,
      created_by_id: user.id,
      arrived_by: :paste,
      received_at: now,
      approved_at: if(approved?, do: now),
      approved_by_id: if(approved?, do: user.id)
    }
    |> AccessKey.insert_changeset(%{allow_secrets: false, label: name})
    |> AccessKey.put_integrity()
    |> Repo.insert!()
  end

  @doc """
  sign_request/6 is the `X-Qory-Signature-Ed25519` a runner sends: the Ed25519 signature
  under `seed` of the request string (`Apiary.Contract.SignedMessage.request/5`), in
  base64url without padding. A `seed` that is not 32 bytes, such as "not the secret", is
  taken as the seed of its SHA-256: a key that is not the access key's, for a test of a
  wrong one.
  """
  def sign_request(seed, key_id, instance_id, method, target, last) do
    seed = if byte_size(seed) == 32, do: seed, else: :crypto.hash(:sha256, seed)
    message = SignedMessage.request(key_id, instance_id, method, target, last)
    Ed25519.encode(:crypto.sign(:eddsa, :none, message, [seed, :ed25519]))
  end

  @doc """
  signed_answer?/1 says whether the answer in `conn` is signed as the contract has it:
  `Cache-Control: no-store, no-transform`, and an `X-Qory-Signature-Ed25519` that
  verifies under the instance's public key (`Apiary.SigningKey`) over the answer string
  of its status, the request's signature, its body and its digest headers.
  """
  def signed_answer?(%Plug.Conn{} = conn) do
    with [request_signature] <- get_req_header(conn, "x-qory-signature-ed25519"),
         [signature] <- get_resp_header(conn, "x-qory-signature-ed25519"),
         ["no-store, no-transform"] <- get_resp_header(conn, "cache-control"),
         {:ok, signature} <- Ed25519.decode(signature, 64) do
      message =
        SignedMessage.answer(
          conn.status,
          request_signature,
          conn.resp_body || "",
          one(get_resp_header(conn, "x-qory-configuration")),
          one(get_resp_header(conn, "x-qory-run-configuration"))
        )

      Ed25519.verify(message, signature, SigningKey.public_key())
    else
      _ -> false
    end
  end

  @doc "unsigned_answer?/1 says whether the answer in `conn` carries no signature."
  def unsigned_answer?(%Plug.Conn{} = conn),
    do: get_resp_header(conn, "x-qory-signature-ed25519") == []

  defp one([value]), do: value
  defp one([]), do: nil

  @doc """
  The key the contract's fixtures are signed under, in the scope's workspace. Test
  support only: no production code accepts a chosen key id or secret.
  """
  def published_key_fixture(%Scope{organisation: organisation, workspace: workspace, user: user}) do
    Repo.insert!(%AccessKey{
      organisation_id: organisation.id,
      workspace_id: workspace.id,
      created_by_id: user.id,
      key_id: @published_key_id,
      label: "the contract's fixtures",
      secret_primary: @published_secret
    })
    # As a verified key does, it carries its workspace (`fetch_for_verification/1`).
    |> Map.put(:workspace, workspace)
  end

  @doc "An event as it is on the wire. `type` is given without the `dev.qory.` prefix."
  def wire_event(subject, sequence, type, data \\ %{}, opts \\ []) do
    %{
      "specversion" => "1.0",
      "id" => Keyword.get_lazy(opts, :id, &Ecto.UUID.generate/0),
      "source" => "urn:qory:run:" <> subject,
      "type" => "dev.qory." <> type,
      "subject" => subject,
      "time" => Keyword.get(opts, :time, "2026-09-16T12:00:00.000Z"),
      "sequence" => sequence |> Integer.to_string() |> String.pad_leading(10, "0"),
      "dataschema" => "https://qory.dev/contracts/runner/v1/events/#{type}.schema.json",
      "data" => data
    }
  end

  @doc "A ping and a start of a fresh run: `{subject, events}`."
  def first_events(subject \\ Ecto.UUID.generate()) do
    {subject,
     [
       wire_event(subject, 1, "ping", %{
         "runner_version" => "0.4.0",
         "events" => ["*"],
         "contract_version" => 1,
         "interval_seconds" => 30
       }),
       wire_event(subject, 2, "run.started", %{
         "runtime" => "claude",
         "runtime_version" => "2.1.0",
         "command" => "claude",
         "args" => ["--print", "hello"],
         "dir" => "/work/shop",
         "interactive" => false,
         "runner_version" => "0.4.0",
         "host" => "dev-laptop",
         "labels" => %{"forge" => "git.example.com", "repository" => "acme/shop"}
       })
     ]}
  end

  @doc """
  Posts `body` (a binary, or events to encode) to the events endpoint as a runner does:
  under `key_id`, signed with the Ed25519 `seed`, from the instance `instance_id/0`, with
  `X-Qory-Contract-Version: 1`. Options: `:signature`, `:instance_id` (nil for none),
  `:instance_name`, `:content_type` (nil for none), `:contract_version` (nil for none),
  `:delivery`, `:run_configuration`, `:user_agent`, `:target` (what is signed and posted
  to, `/v1/events` unless given), `:headers` (a list sent beside the others).
  """
  def signed_post(conn, key_id, seed, body, opts \\ []) do
    body = if is_binary(body), do: body, else: Jason.encode!(body)
    instance_id = Keyword.get(opts, :instance_id, @instance_id)
    target = Keyword.get(opts, :target, "/v1/events")

    signature =
      Keyword.get_lazy(opts, :signature, fn ->
        sign_request(seed, key_id, instance_id, "POST", target, body)
      end)

    headers =
      [
        {"x-qory-access-key-id", key_id},
        {"x-qory-instance-id", instance_id},
        {"x-qory-instance-name", Keyword.get(opts, :instance_name, "build-01")},
        {"x-qory-signature-ed25519", signature},
        {"user-agent", Keyword.get(opts, :user_agent, "qory-runner/0.4.0")},
        {"content-type", Keyword.get(opts, :content_type, @content_type)},
        {"x-qory-contract-version", Keyword.get(opts, :contract_version, "1")},
        {"x-qory-delivery", Keyword.get_lazy(opts, :delivery, &Ecto.UUID.generate/0)},
        {"x-qory-run-configuration", Keyword.get(opts, :run_configuration)}
      ]

    # The extra headers are added beside the others, not in their place: that is
    # how a header is sent twice.
    headers
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> then(&%{&1 | req_headers: &1.req_headers ++ Keyword.get(opts, :headers, [])})
    |> Phoenix.ConnTest.dispatch(ApiaryWeb.Endpoint, :post, target, body)
  end

  @doc """
  A signed GET of `target`, a path with its query exactly as it is sent, as a runner
  sends it: under `key_id`, signed with the Ed25519 `seed`, from the instance
  `instance_id/0`, with `X-Qory-Contract-Version: 1`. Options: `:timestamp` (nil for
  none, signed as an empty line), `:signature`, `:instance_id` (nil for none),
  `:contract_version` (nil for none, a list for each of its values), `:user_agent`,
  `:headers` (sent beside the others).
  """
  def signed_get(conn, key_id, seed, target, opts \\ []) do
    timestamp =
      case Keyword.get(opts, :timestamp, System.os_time(:second)) do
        nil -> nil
        timestamp -> to_string(timestamp)
      end

    instance_id = Keyword.get(opts, :instance_id, @instance_id)

    signature =
      Keyword.get_lazy(opts, :signature, fn ->
        sign_request(seed, key_id, instance_id, "GET", target, timestamp || "")
      end)

    versions =
      for version <- opts |> Keyword.get(:contract_version, "1") |> List.wrap(),
          do: {"x-qory-contract-version", to_string(version)}

    [
      {"x-qory-access-key-id", key_id},
      {"x-qory-instance-id", instance_id},
      {"x-qory-instance-name", "build-01"},
      {"x-qory-timestamp", timestamp},
      {"x-qory-signature-ed25519", signature},
      {"user-agent", Keyword.get(opts, :user_agent, "qory-runner/0.4.0")}
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> then(&%{&1 | req_headers: &1.req_headers ++ versions ++ Keyword.get(opts, :headers, [])})
    |> Phoenix.ConnTest.dispatch(ApiaryWeb.Endpoint, :get, target, nil)
  end

  @doc """
  The runner's contract directory: `RUNNER_CONTRACT_DIR`, else the contract at the
  commit in `.runner-contract-ref`, taken once from the sibling checkout of qoryai/runner
  (`../../runner/main`) with `git archive` into the build directory, whatever that
  checkout has checked out; else nil. The checkout is only read.
  """
  def contract_dir do
    case System.get_env("RUNNER_CONTRACT_DIR") do
      dir when dir in [nil, ""] -> pinned_dir()
      dir -> if File.dir?(dir), do: Path.expand(dir)
    end
  end

  @doc "The commit of qoryai/runner in `.runner-contract-ref`."
  def pinned_ref do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.join(".runner-contract-ref")
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != "" and not String.starts_with?(&1, "#")))
  end

  defp pinned_dir do
    ref = pinned_ref()
    root = Path.join([Mix.Project.build_path(), "runner-contract", ref])
    dir = Path.join(root, @contract)
    sibling = Path.expand(@sibling, Path.dirname(Mix.Project.project_file()))

    cond do
      File.dir?(dir) -> dir
      File.dir?(sibling) and System.find_executable("git") -> archive(sibling, ref, root, dir)
      true -> nil
    end
  end

  # Extracted beside the destination and renamed into place, so two suites starting
  # together never read half a directory.
  defp archive(sibling, ref, root, dir) do
    case System.cmd("git", ["-C", sibling, "archive", "--format=tar", ref, @contract],
           stderr_to_stdout: false
         ) do
      {tar, 0} ->
        partial = "#{root}.#{System.unique_integer([:positive])}"
        File.mkdir_p!(partial)
        :ok = :erl_tar.extract({:binary, tar}, [{:cwd, String.to_charlist(partial)}])

        case File.rename(partial, root) do
          :ok -> :ok
          {:error, _already_there} -> File.rm_rf!(partial)
        end

        if File.dir?(dir), do: dir

      {_output, _status} ->
        nil
    end
  end

  @doc "contract_json!/1 decodes `fixtures/<path>` of the runner's contract directory."
  def contract_json!(path), do: path |> contract_file!() |> Jason.decode!()

  @doc "contract_file!/1 reads `fixtures/<path>` of the runner's contract directory as bytes."
  def contract_file!(path) do
    dir = contract_dir() || raise "no runner contract directory"
    dir |> Path.join("fixtures") |> Path.join(path) |> File.read!()
  end

  @doc """
  known_answers!/1 decodes `fixtures/known-answers/<name>.json`: `"keys"`,
  `"signatures"`, `"discovery"` or `"small-order"`.
  """
  def known_answers!(name) when name in ~w(keys signatures discovery small-order),
    do: contract_json!("known-answers/#{name}.json")

  @doc """
  fixture_key!/1 is one of the contract's fixture keys of `known-answers/keys.json`
  (`"access_key"`, `"pending_access_key"`, `"signing_key"`, `"next_signing_key"`), with
  its raw `:seed`, its raw `:public_key` derived from the seed and checked against the
  published one, and the published `:fingerprint`, plus `:access_key_id` and
  `:instance_id` where the file gives them. Test support only: every instance refuses
  these keys.
  """
  def fixture_key!(name)
      when name in ~w(access_key pending_access_key signing_key next_signing_key) do
    entry = Map.fetch!(known_answers!("keys"), name)

    encoded_seed =
      case entry do
        %{"secret" => "qak_" <> seed} -> seed
        %{"seed" => seed} -> seed
      end

    {:ok, seed} = Apiary.Contract.Ed25519.decode(encoded_seed, 32)
    {public_key, _secret} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {:ok, ^public_key} = Apiary.Contract.Ed25519.decode(entry["public_key"], 32)

    %{
      seed: seed,
      public_key: public_key,
      fingerprint: entry["fingerprint"],
      access_key_id: entry["access_key_id"],
      instance_id: entry["instance_id"]
    }
  end

  @doc """
  signed_fixtures/0 is every `fixtures/signed/*.json` of the runner's contract
  directory, decoded, by file name, sorted; empty without the directory.
  """
  def signed_fixtures do
    case contract_dir() do
      nil ->
        []

      dir ->
        dir
        |> Path.join("fixtures/signed/*.json")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.map(&{Path.basename(&1), &1 |> File.read!() |> Jason.decode!()})
    end
  end
end
