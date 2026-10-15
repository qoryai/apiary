defmodule Apiary.IntegrationsContract do
  @moduledoc """
  Test helpers for the integration contract: where its directory is
  (`contracts/integration/v1` of qoryai/integrations at the commit in
  `.integrations-contract-ref`), its fixtures, its fixture keys held as the instance under
  test holds them, and requests signed as an adapter signs them. Test support only.
  """

  @behaviour JSV.Resolver

  import Plug.Conn, only: [put_req_header: 3]

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Contract.Ed25519
  alias Apiary.Repo

  @sibling "../../integrations/main"
  @contract "contracts/integration/v1"
  @base "https://qory.dev/contracts/integration/v1/"

  @doc """
  The integration contract's directory: `INTEGRATIONS_CONTRACT_DIR`, set to
  `contracts/integration/v1` of a qoryai/integrations checkout at the commit in
  `.integrations-contract-ref`. Unset, the pinned commit is read from the maintainers'
  checkout beside this one, when there is one. Nil when there is neither.
  """
  def contract_dir do
    case System.get_env("INTEGRATIONS_CONTRACT_DIR") do
      dir when dir in [nil, ""] -> pinned_dir()
      dir -> if File.dir?(dir), do: Path.expand(dir)
    end
  end

  @doc "The commit of qoryai/integrations in `.integrations-contract-ref`."
  def pinned_ref do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.join(".integrations-contract-ref")
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != "" and not String.starts_with?(&1, "#")))
  end

  defp pinned_dir do
    ref = pinned_ref()
    root = Path.join([Mix.Project.build_path(), "integrations-contract", ref])
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

  @doc "file!/1 reads `<path>` of the contract's directory as bytes."
  def file!(path) do
    dir = contract_dir() || raise "no integration contract directory"
    dir |> Path.join(path) |> File.read!()
  end

  @doc "json!/1 decodes `<path>` of the contract's directory."
  def json!(path), do: path |> file!() |> Jason.decode!()

  @doc "fixture!/1 decodes `fixtures/<path>` of the contract's directory."
  def fixture!(path), do: json!("fixtures/" <> path)

  @doc """
  The validator of one of the contract's documents by its schema's file name, such as
  `"refusal.schema.json"`.
  """
  def schema!(file) do
    dir = contract_dir() || raise "no integration contract directory"
    JSV.build!(%{"$ref" => @base <> file}, resolver: {__MODULE__, dir}, formats: true)
  end

  @doc "`:ok`, or `{:error, error}` with what the schema refuses in `document`, decoded."
  def validate(root, document) do
    case JSV.validate(document, root) do
      {:ok, _document} -> :ok
      {:error, error} -> {:error, JSV.normalize_error(error)}
    end
  end

  # The schemas name each other by URL under the contract's base; the files are beside
  # each other under the contract's directory. Nothing is fetched.
  @impl JSV.Resolver
  def resolve(@base <> path, dir) do
    file = Path.expand(path, dir)

    with true <- String.starts_with?(file, dir <> "/"),
         {:ok, body} <- File.read(file),
         {:ok, schema} <- Jason.decode(body) do
      {:ok, schema}
    else
      _ -> {:error, {:not_in_the_contract, path}}
    end
  end

  def resolve(url, _dir), do: {:error, {:not_in_the_contract, url}}

  @doc """
  key!/1 is a key of `fixtures/adapter/signed/keys.json`: `"access_key"`, with its raw
  `:seed`, `:public_key`, `:access_key_id` and `:instance_id`, or `"server_key"`, with its
  raw `:seed` and `:public_key`. The public key is derived from the seed and checked
  against the published one.
  """
  def key!(name) when name in ~w(access_key server_key) do
    entry = Map.fetch!(fixture!("adapter/signed/keys.json"), name)

    encoded_seed =
      case entry do
        %{"secret" => "qak_" <> seed} -> seed
        %{"seed" => seed} -> seed
      end

    {:ok, seed} = Ed25519.decode(encoded_seed, 32)
    {public_key, _secret} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {:ok, ^public_key} = Ed25519.decode(entry["public_key"], 32)

    %{
      seed: seed,
      public_key: public_key,
      access_key_id: entry["access_key_id"],
      instance_id: entry["instance_id"]
    }
  end

  @doc """
  The contract's fixture access key, held under its published id on `adapter`, active, as
  the instance under test holds it. Written straight into the table, past the key checks,
  which refuse every fixture key: test support only.
  """
  def fixture_access_key!(%Scope{user: user}, adapter) do
    %{public_key: public_key, access_key_id: key_id} = key!("access_key")

    %AccessKey{
      id: Ecto.UUID.generate(),
      organisation_id: adapter.organisation_id,
      workspace_id: adapter.workspace_id,
      node_id: adapter.id,
      key_id: key_id,
      public_key: public_key,
      created_by_id: user.id,
      arrived_by: :browser,
      received_at: DateTime.utc_now()
    }
    |> AccessKey.insert_changeset(%{allow_secrets: false, label: "integration fixture"})
    |> AccessKey.put_integrity()
    |> Repo.insert!()
  end

  @doc """
  Posts `body` (a binary, or a map to encode) to `target` as an adapter does: under
  `key_id`, signed with the Ed25519 `seed`, from `instance_id`, with
  `X-Qory-Contract-Version: 1` and `Content-Type: application/json`. Options:
  `:signature`, `:instance_id` (nil for none), `:content_type` (nil for none),
  `:contract_version` (nil for none), `:headers` (sent beside the others).
  """
  def adapter_post(conn, key_id, seed, target, body, opts \\ []) do
    body = if is_binary(body), do: body, else: Jason.encode!(body)
    instance_id = Keyword.get(opts, :instance_id, "i_gYKDhIWGh4iJiouMjY6PkA")

    signature =
      Keyword.get_lazy(opts, :signature, fn ->
        Apiary.ContractFixtures.sign_request(seed, key_id, instance_id, "POST", target, body)
      end)

    [
      {"x-qory-access-key-id", key_id},
      {"x-qory-instance-id", instance_id},
      {"x-qory-signature-ed25519", signature},
      {"user-agent", "acme-tracker-adapter"},
      {"content-type", Keyword.get(opts, :content_type, "application/json")},
      {"x-qory-contract-version", Keyword.get(opts, :contract_version, "1")}
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> then(&%{&1 | req_headers: &1.req_headers ++ Keyword.get(opts, :headers, [])})
    |> Phoenix.ConnTest.dispatch(ApiaryWeb.Endpoint, :post, target, body)
  end
end
