defmodule Apiary.ContractFixtures do
  @moduledoc """
  Test helpers for the receiving side of the server contract: events as they
  are on the wire, signed deliveries, the published key of the contract's
  fixtures, and where the runner's contract directory is.
  """

  import Plug.Conn, only: [put_req_header: 3]

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Contract.Signature
  alias Apiary.Repo

  @content_type "application/cloudevents-batch+json"
  @published_key_id "ak_f1xt0re000000000"
  @published_secret "fixture-secret-not-a-real-one"
  @default_dir "../../runner/main/contracts/runner/v1"

  def content_type, do: @content_type
  def published_key_id, do: @published_key_id
  def published_secret, do: @published_secret

  @doc """
  The key the contract's fixtures are signed under, in the scope's hive. Test
  support only: no production code accepts a chosen key id or secret.
  """
  def published_key_fixture(%Scope{organisation: organisation, hive: hive, user: user}) do
    Repo.insert!(%AccessKey{
      organisation_id: organisation.id,
      hive_id: hive.id,
      created_by_id: user.id,
      key_id: @published_key_id,
      label: "the contract's fixtures",
      secret_primary: @published_secret
    })
  end

  @doc "An event as it is on the wire. `type` is given without the `ai.qory.` prefix."
  def wire_event(subject, sequence, type, data \\ %{}, opts \\ []) do
    %{
      "specversion" => "1.0",
      "id" => Keyword.get_lazy(opts, :id, &Ecto.UUID.generate/0),
      "source" => "urn:qory:run:" <> subject,
      "type" => "ai.qory." <> type,
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
  `secret` under `key_id`. Options: `:signature`, `:content_type` (nil for none),
  `:contract_version` (nil for none; 1 by default), `:delivery`,
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
        {"x-qory-contract-version", opts |> Keyword.get(:contract_version, 1) |> to_header()},
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
  A signed GET of `target`, a path with its query exactly as it is sent. Options:
  `:timestamp`, `:signature`, `:headers` (sent beside the others).
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
    |> put_req_header("x-qory-contract-version", "1")
    |> then(&%{&1 | req_headers: &1.req_headers ++ Keyword.get(opts, :headers, [])})
    |> Phoenix.ConnTest.dispatch(ApiaryWeb.Endpoint, :get, target, nil)
  end

  defp to_header(nil), do: nil
  defp to_header(value), do: to_string(value)

  @doc """
  The runner's contract directory: `RUNNER_CONTRACT_DIR`, else the sibling
  checkout when it is there, else nil.
  """
  def contract_dir do
    case System.get_env("RUNNER_CONTRACT_DIR") do
      dir when dir in [nil, ""] -> if File.dir?(@default_dir), do: Path.expand(@default_dir)
      dir -> if File.dir?(dir), do: Path.expand(dir)
    end
  end
end
