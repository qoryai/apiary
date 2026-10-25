defmodule Apiary.NodesFixtures do
  @moduledoc "Test helpers for nodes and node pools, their instances and their runs."

  import Ecto.Query, only: [from: 2]

  alias Apiary.Nodes
  alias Apiary.Nodes.{Instance, Node}
  alias Apiary.Repo
  alias Apiary.Runs.Run

  def unique_node_name, do: "build-#{System.unique_integer([:positive])}"

  @doc """
  `base` with a fresh number after it: a name for an adapter, unique among the instance's
  adapters, so that async tests do not make two of one name at once.
  """
  def unique_adapter_name(base), do: "#{base} #{System.unique_integer([:positive])}"

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

  @doc """
  An adapter installed with Qory Apiary as `name`, else a fresh name, by the instance
  (`Apiary.Adapters.install/2`): found if one in use is installed as it. Whether the name
  is listed (`Apiary.Adapters.Installed`) is the test's to set.
  """
  def installed_adapter_fixture(name \\ nil) do
    name = name || "tracker-#{System.unique_integer([:positive])}"

    {:ok, adapter} =
      Apiary.Adapters.install(Apiary.OrganisationsFixtures.instance_scope(), name)

    adapter
  end

  @doc """
  The instance's node pool, with no organisation and no workspace, written straight into
  the table, on `:default` unless `attrs` gives its `gateway_choice`. The instance has
  one in use at most, so a test that makes it is not async.
  """
  def instance_pool_fixture(attrs \\ %{}) do
    Repo.insert!(%Node{
      kind: :pool,
      public_id: Apiary.PublicId.generate("np"),
      name: Map.get(Map.new(attrs), :name, unique_node_name()),
      organisation_id: nil,
      workspace_id: nil,
      instance_limit: Map.get(Map.new(attrs), :instance_limit),
      gateway_choice: Map.get(Map.new(attrs), :gateway_choice, :default),
      gateway_id: Map.get(Map.new(attrs), :gateway_id),
      installed_as: Map.get(Map.new(attrs), :installed_as)
    })
  end

  @doc """
  The instance's gateway, with no organisation and no workspace, at
  `https://gateway.example` unless `attrs` gives its `url`, written straight into the
  table. The instance has one in use at most, so a test that makes it is not async.
  """
  def instance_gateway_fixture(attrs \\ %{}) do
    Repo.insert!(%Node{
      kind: :gateway,
      public_id: Apiary.PublicId.generate("ng"),
      name: Map.get(Map.new(attrs), :name, unique_node_name()),
      organisation_id: nil,
      workspace_id: nil,
      url: Map.get(Map.new(attrs), :url, "https://gateway.example"),
      gateway_choice: :direct,
      installed_as: Map.get(Map.new(attrs), :installed_as)
    })
  end

  @descriptions Path.expand("../../fixtures/integration-contract", __DIR__)

  @doc """
  Records on `adapter` what the source role of the integrations contract's description
  fixture `name` says of its items and its collections
  (`Apiary.Nodes.Node.source_role_changeset/2`), as a start does
  (`Apiary.Adapters.declare/2`), but with no feed entry for a change of its `items`:
  `example-tracker.json` names its items issue and issues and its collections project
  and projects, `example-projects.json` says it has no items and names its collections
  project and projects, `acme-tracker.json` names none and has items. Returns the adapter
  as it now is.
  """
  def describe_source(%Node{kind: :adapter} = adapter, name) do
    {:ok, description} =
      @descriptions |> Path.join(name) |> File.read!() |> Apiary.Integrations.Description.parse()

    adapter |> Node.source_role_changeset(description) |> Repo.update!()
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

  @setup_url "https://tracker.example.com/setup?site=main"

  @doc """
  An adapter an instance admin may set up (`connectable_adapter_fixture/1`): with its key,
  and an address to be set up at, #{@setup_url}, as an adapter that is not set up yet
  declares one. Returns what `connectable_adapter_fixture/1` does.
  """
  def settable_adapter_fixture(attrs \\ %{}) do
    %{adapter: adapter} = made = connectable_adapter_fixture(attrs)

    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^adapter.id), set: [setup_url: @setup_url])

    %{made | adapter: Repo.get!(Node, adapter.id)}
  end

  @doc """
  Links `collection` (`Apiary.Adapters.Collection`) to `workspace`, of the same
  organisation, or to none, as nothing in the product does: it asks no one and writes no
  feed entry. For tests that need a linked collection without the assign's entries
  (`Apiary.Adapters.Collections.assign_collections/4`). `{:ok, collection}`.
  """
  def set_collection_workspace(collection, workspace) do
    collection
    |> Ecto.Changeset.change(workspace_id: workspace && workspace.id)
    |> Repo.update()
  end

  @doc """
  A live collection (`Apiary.Adapters.Collection`) of a connection of the scope's
  organisation to a fresh adapter, written as it stands, as nothing in the product does:
  no listing, no feed entry, nothing queued. Linked to the scope's workspace, its target
  `code.example.com` and `acme/` and its ref, its `environment_ref` `env-1`, unless
  `attrs` sets `:workspace_id`, `:external_ref`, `:target_system`, `:target_path` or
  `:environment_ref` (nil for none).
  """
  def collection_fixture(scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    %{adapter: adapter} = connectable_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter, :listed)
    ref = Map.get(attrs, :external_ref, "R_#{System.unique_integer([:positive])}")

    Repo.insert!(%Apiary.Adapters.Collection{
      public_id: Apiary.PublicId.generate(Apiary.Adapters.Collection.prefix()),
      organisation_id: scope.organisation.id,
      adapter_id: adapter.id,
      connection_id: connection.id,
      workspace_id: Map.get(attrs, :workspace_id, scope.workspace.id),
      external_ref: ref,
      url: "https://code.example.com/acme/" <> ref,
      title: ref,
      target_system: Map.get(attrs, :target_system, "code.example.com"),
      target_path: Map.get(attrs, :target_path, "acme/" <> ref),
      environment_ref: Map.get(attrs, :environment_ref, "env-1"),
      last_listed_at: DateTime.utc_now(:second)
    })
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

    # A connected connection's pass came back linked, so a grant report may name its nonce.
    if state != :pending do
      {:ok, _pass} = Apiary.Adapters.LinkedPass.insert(connection, connection.pass_nonce, now)
    end

    {connection, nonce}
  end

  @doc """
  The ref of a live grant of `connection`, as a listing of its collections gives it in
  each collection's `grant_ref`: `ref`, else `G_` and the connection's public id, so that
  the grants of two connections of one adapter differ. The grant is made as an accepted
  report makes one, for the external account `1001`, `acme`, with a nonce of no pass,
  unless the connection has a live grant with that ref already. It writes no feed entry
  and no trail entry.
  """
  def listing_grant(%Apiary.Adapters.Connection{} = connection, ref \\ nil) do
    alias Apiary.Adapters.Grant

    ref = ref || "G_" <> connection.public_id

    live =
      Repo.one(
        from g in Grant,
          where: g.connection_id == ^connection.id and g.grant_ref == ^ref,
          where: is_nil(g.ended_at)
      )

    if is_nil(live) do
      Repo.insert!(%Grant{
        public_id: Apiary.PublicId.generate(Grant.prefix()),
        organisation_id: connection.organisation_id,
        adapter_id: connection.adapter_id,
        connection_id: connection.id,
        grant_ref: ref,
        account_ref: "1001",
        account_title: "acme",
        state: :live,
        pass_nonce: :crypto.strong_rand_bytes(16),
        granted_at: DateTime.utc_now()
      })
    end

    ref
  end

  @doc """
  Sets the expiry kept for the latest connect pass of the pending connection `public_id`
  to `validity/0` seconds less a minute after now, truncated to the second, which is when
  a pass made a minute before now expires, so the next press of Install takes the same
  connection with a new pass. A press in the same second as the
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
  table: `node_instance_id`, the `instance_id` given or a fresh one, `name`, and seen
  first and last at `seen_at` (now unless given), or at `first_seen_at` and
  `last_seen_at`.
  """
  def instance_fixture(%Node{} = node, attrs \\ %{}) do
    attrs = Map.new(attrs)
    seen = Map.get(attrs, :seen_at, DateTime.utc_now())

    Repo.insert!(%Instance{
      organisation_id: node.organisation_id,
      workspace_id: node.workspace_id,
      node_id: node.id,
      node_instance_id: Map.get(attrs, :instance_id, unique_instance_id()),
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
      node_run_id: Ecto.UUID.generate(),
      node_id: node.id,
      node_instance_id: instance_id,
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change(Map.new(attrs))
    |> Repo.insert!()
  end
end
