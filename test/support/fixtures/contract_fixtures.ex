defmodule Apiary.ContractFixtures do
  @moduledoc """
  Test helpers for the receiving side of the server contract: events as they
  are on the wire, signed deliveries, the published key of the contract's
  fixtures, where the runner's contract directory is, and its fixtures: the
  Ed25519 keys, known answers, signed requests and enrolments.
  """

  import Plug.Conn, only: [put_req_header: 3]

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Contract.Signature
  alias Apiary.Repo

  @content_type "application/cloudevents-batch+json"
  @published_key_id "ak_f1xt0re000000000"
  @published_secret "fixture-secret-not-a-real-one"
  @sibling "../../runner/main"
  @contract "contracts/runner/v1"

  def content_type, do: @content_type
  def published_key_id, do: @published_key_id
  def published_secret, do: @published_secret

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
         "contract_version" => 1
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
  Posts `body` (a binary, or events to encode) to the events endpoint, signed with
  `secret` under `key_id`, with `X-Qory-Contract-Version: 1` as the runner sends it.
  Options: `:signature`, `:content_type` (nil for none), `:delivery`,
  `:run_configuration`, `:user_agent`, `:headers` (a list sent beside the others).
  """
  def signed_post(conn, key_id, secret, body, opts \\ []) do
    body = if is_binary(body), do: body, else: Jason.encode!(body)

    headers =
      [
        {"x-qory-access-key", key_id},
        {"x-qory-signature-256", Keyword.get(opts, :signature, Signature.sign(secret, body))},
        {"user-agent", Keyword.get(opts, :user_agent, "qory-runner/0.4.0")},
        {"content-type", Keyword.get(opts, :content_type, @content_type)},
        {"x-qory-contract-version", "1"},
        {"x-qory-delivery", Keyword.get_lazy(opts, :delivery, &Ecto.UUID.generate/0)},
        {"x-qory-run-configuration", Keyword.get(opts, :run_configuration)}
      ]

    # The extra headers are added beside the others, not in their place: that is
    # how a header is sent twice.
    headers
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> then(&%{&1 | req_headers: &1.req_headers ++ Keyword.get(opts, :headers, [])})
    |> Phoenix.ConnTest.dispatch(ApiaryWeb.Endpoint, :post, "/v1/events", body)
  end

  @doc """
  A signed GET of `target`, a path with its query exactly as it is sent, with
  `X-Qory-Contract-Version: 1` as the runner sends it. Options: `:timestamp`,
  `:signature`, `:contract_version` (nil for none), `:headers` (sent beside the others).
  """
  def signed_get(conn, key_id, secret, target, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, System.os_time(:second))
    canonical = Signature.canonical_string("GET", target, timestamp)

    conn
    |> put_req_header("x-qory-access-key", key_id)
    |> put_req_header("x-qory-timestamp", to_string(timestamp))
    |> put_req_header(
      "x-qory-signature-256",
      Keyword.get(opts, :signature, Signature.sign(secret, canonical))
    )
    |> put_req_header("user-agent", "qory-runner/0.4.0")
    |> then(fn conn ->
      case Keyword.get(opts, :contract_version, "1") do
        nil -> conn
        version -> put_req_header(conn, "x-qory-contract-version", version)
      end
    end)
    |> then(&%{&1 | req_headers: &1.req_headers ++ Keyword.get(opts, :headers, [])})
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
