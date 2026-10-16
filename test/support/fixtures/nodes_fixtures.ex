defmodule Apiary.NodesFixtures do
  @moduledoc "Test helpers for nodes and node pools, their instances and their runs."

  import Ecto.Query, only: [from: 2]

  alias Apiary.Nodes
  alias Apiary.Nodes.{Instance, Node}
  alias Apiary.Repo
  alias Apiary.Runs.Run

  def unique_node_name, do: "build-#{System.unique_integer([:positive])}"

  @doc """
  A node of the scope's workspace, made by the scope's person, who must be an owner or
  an admin: kind `node` unless `attrs` says `pool`.
  """
  def node_fixture(scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{kind: "node", name: unique_node_name()})
    {:ok, node} = Nodes.create_node(scope, attrs)
    node
  end

  @doc "A node pool of the scope's workspace, with no instance limit unless `attrs` sets one."
  def pool_fixture(scope, attrs \\ %{}),
    do: node_fixture(scope, Enum.into(attrs, %{kind: "pool", name: unique_node_name()}))

  @doc """
  A gateway of the scope's workspace, at `https://gateway.example` unless `attrs` gives
  its `url`.
  """
  def gateway_fixture(scope, attrs \\ %{}),
    do:
      node_fixture(
        scope,
        Enum.into(attrs, %{
          kind: "gateway",
          name: unique_node_name(),
          url: "https://gateway.example"
        })
      )

  @doc """
  A gateway of the scope's organisation, one that lives at the organisation with no
  workspace, made by the scope's person, an owner or an admin: at
  `https://gateway.example` unless `attrs` gives its `url`.
  """
  def organisation_gateway_fixture(scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: unique_node_name(), url: "https://gateway.example"})
    {:ok, gateway} = Nodes.create_organisation_gateway(scope, attrs)
    gateway
  end

  @doc """
  An adapter of the instance, with no organisation, made by an instance admin
  (`Apiary.OrganisationsFixtures.instance_admin_scope/0`) on an instance with the feature
  adapters belong to: named `attrs`'s `name`, else a fresh name.
  """
  def adapter_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: unique_node_name()})

    {:ok, adapter} =
      Apiary.Adapters.create_adapter(Apiary.OrganisationsFixtures.instance_admin_scope(), attrs)

    adapter
  end

  @connect_url "https://tracker.example.com/connect"

  @doc """
  An adapter of the instance an organisation may connect (`adapter_fixture/1`): with a
  connect address, #{@connect_url}, and a key enrolled on it by an instance admin. Returns
  `%{adapter: adapter, access_key: key, pair: key pair}`, the pair's secret to sign with
  as the adapter.
  """
  def connectable_adapter_fixture(attrs \\ %{}) do
    adapter = adapter_fixture(attrs)

    %{access_key: key, pair: pair} =
      Apiary.AccessKeysFixtures.enrolled_key_fixture(
        Apiary.OrganisationsFixtures.instance_admin_scope(),
        adapter
      )

    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
        set: [connect_url: @connect_url]
      )

    %{adapter: Repo.get!(Node, adapter.id), access_key: key, pair: pair}
  end

  @doc """
  The connection of the scope's organisation to `adapter`, connectable
  (`connectable_adapter_fixture/1`), started by the scope's person, an owner or an admin
  (`Apiary.Adapters.connect/2`), then in `state`: `:pending`, as started; `:connected`,
  as a return that says it is linked leaves it; `:listed`, connected, and named by the
  adapter's first listing. Returns `{connection, session_nonce}`, the nonce of its pass
  in base64url, as the person's session keeps it.
  """
  def connection_fixture(scope, %Node{} = adapter, state \\ :listed) do
    alias Apiary.Adapters.Connection

    {:ok, _url, {public_id, nonce}} = Apiary.Adapters.connect(scope, adapter)
    connection = Repo.get_by!(Connection, public_id: public_id)
    now = DateTime.utc_now()

    connected = [state: :connected, connected_at: now, pass_nonce_used_at: now]

    connection =
      case state do
        :pending ->
          connection

        :connected ->
          connection |> Ecto.Changeset.change(connected) |> Repo.update!()

        :listed ->
          connection
          |> Ecto.Changeset.change([listed_at: now] ++ connected)
          |> Repo.update!()
      end

    {connection, nonce}
  end

  @doc """
  Moves the expiry kept for the latest connect pass of the pending connection
  `public_id` a minute back, as if that pass was made a minute ago, so the next press of
  Install takes the same connection with a new pass. A press in the same second as the
  pass before it would instead end the connection as `replaced` and start a new one
  (`Apiary.Adapters.Connections.start/3`).
  """
  def pass_made_earlier(public_id) do
    alias Apiary.Adapters.{ConnectPass, Connection}

    earlier =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.add(ConnectPass.validity() - 60, :second)

    {1, _} =
      Repo.update_all(from(c in Connection, where: c.public_id == ^public_id),
        set: [pass_expires_at: earlier]
      )

    :ok
  end

  @doc """
  A return as an adapter hands one back (`Apiary.Adapters.ReturnToken`), signed with
  `secret`, the adapter's key's: for the connection `connection_id` and the pass's
  `nonce` (16 bytes, or base64url), `linked` unless `opts[:outcome]` says otherwise, with
  `opts[:reason]` for `refused`, expiring `opts[:expires_at]`, else 300 s from now. `opts`
  may give the whole payload as `:payload`, a map or the bytes.
  """
  def return_token(secret, connection_id, nonce, opts \\ []) do
    alias Apiary.Contract.{Ed25519, SignedMessage}

    nonce = if byte_size(nonce) == 16, do: Ed25519.encode(nonce), else: nonce

    expires_at =
      Keyword.get_lazy(opts, :expires_at, fn ->
        DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.truncate(:second)
      end)

    members =
      %{
        "version" => 1,
        "connection_id" => connection_id,
        "nonce" => nonce,
        "outcome" => Atom.to_string(Keyword.get(opts, :outcome, :linked)),
        "expires_at" => DateTime.to_iso8601(expires_at)
      }
      |> then(fn members ->
        case Keyword.get(opts, :reason) do
          nil -> members
          reason -> Map.put(members, "reason", Atom.to_string(reason))
        end
      end)

    payload =
      case Keyword.get(opts, :payload, members) do
        bytes when is_binary(bytes) -> bytes
        map -> Jason.encode!(map)
      end

    signature =
      :crypto.sign(:eddsa, :none, SignedMessage.connect_return(payload), [secret, :ed25519])

    Ed25519.encode(payload) <> "." <> Ed25519.encode(signature)
  end

  @doc """
  An instance of `node` as `Apiary.Nodes.seen/3` leaves it, written straight into the
  table: `instance_id` (a fresh one unless given), `name`, and seen first and last at
  `seen_at` (now unless given), or at `first_seen_at` and `last_seen_at`.
  """
  def instance_fixture(%Node{} = node, attrs \\ %{}) do
    attrs = Map.new(attrs)
    seen = Map.get(attrs, :seen_at, DateTime.utc_now())

    Repo.insert!(%Instance{
      organisation_id: node.organisation_id,
      workspace_id: node.workspace_id,
      node_id: node.id,
      instance_id: Map.get(attrs, :instance_id, unique_instance_id()),
      name: Map.get(attrs, :name),
      first_seen_at: Map.get(attrs, :first_seen_at, seen),
      last_seen_at: Map.get(attrs, :last_seen_at, seen),
      last_forager_version: Map.get(attrs, :last_forager_version, "0.7.0")
    })
  end

  @doc "A fresh instance id, as Forager would claim one."
  def unique_instance_id, do: "i_#{System.unique_integer([:positive])}"

  @doc """
  A run of `node` claimed by `instance_id`, written straight into the table as the
  receiver will create it: pending, first heard of now, unless `attrs` says otherwise
  (`state`, `inserted_at`, `started_at`, `last_heartbeat_at`, …).
  """
  def node_run_fixture(%Node{} = node, instance_id, attrs \\ %{}) do
    now = DateTime.utc_now()

    %Run{
      organisation_id: node.organisation_id,
      workspace_id: node.workspace_id,
      run_id: Ecto.UUID.generate(),
      node_id: node.id,
      instance_id: instance_id,
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change(Map.new(attrs))
    |> Repo.insert!()
  end
end
