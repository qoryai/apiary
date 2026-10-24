defmodule Apiary.Nodes.InstalledTest do
  # The instance's node pool and gateway (`Apiary.Nodes.Installed`): the settings that
  # declare them and their checks at boot, then the installer's pass
  # (`Apiary.Adapters.Installer.pass/0`): each made once, its code written to its folder
  # while it has no key, the pool's without stored secrets and the gateway's with them, the
  # enrolment with the file's code, a revocation that brings a code at once, and a node no
  # longer declared, whose codes are cancelled. Not async: the settings, the directory and
  # the instance's one pool and one gateway are the whole node's.
  use Apiary.DataCase, async: false

  import Ecto.Query
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Adapters}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Adapters.{Installed, Installer}
  alias Apiary.Adapters.Installed.CodeFile
  alias Apiary.Audit.Entry
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}
  alias Apiary.Nodes.Installed, as: NodesInstalled
  alias Apiary.Nodes.Node

  @moduletag needs: :factory
  @moduletag :tmp_dir

  @keys [
    :installed_adapters,
    :installed_nodes,
    :installed_pool_setting,
    :installed_gateway_setting,
    :installed_gateway_url_setting,
    :enrolment_dir_setting
  ]

  setup %{tmp_dir: dir} do
    saved = for key <- @keys, do: {key, Application.fetch_env(:apiary, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:apiary, key, value)
          :error -> Application.delete_env(:apiary, key)
        end
      end
    end)

    Application.put_env(:apiary, :enrolment_dir_setting, dir)
    Application.put_env(:apiary, :installed_adapters, [])
    declare(%{pool: "pool", gateway: "gateway", url: "https://gateway.example"})

    %{dir: dir, scope: instance_scope(), admin: instance_admin_scope()}
  end

  # An edition whose instance has no organisation yet: it is not set up.
  defmodule NotSetUp do
    def instance_organisation_id, do: nil
  end

  defp declare(declared), do: Application.put_env(:apiary, :installed_nodes, declared)

  defp boot(pool, gateway, url) do
    Application.put_env(:apiary, :installed_pool_setting, pool)
    Application.put_env(:apiary, :installed_gateway_setting, gateway)
    Application.put_env(:apiary, :installed_gateway_url_setting, url)
    NodesInstalled.boot!(["tracker"])
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp declared_node(kind), do: Repo.one!(NodesInstalled.live_query(kind))

  defp entries(action, %Node{id: id}) do
    Repo.all(
      from e in Entry,
        where: e.action == ^to_string(action) and e.subject_id == ^id,
        order_by: [asc: e.inserted_at]
    )
  end

  defp outstanding(%Node{id: id}) do
    now = DateTime.utc_now()

    Repo.all(
      from c in EnrolmentCode,
        where: c.node_id == ^id and is_nil(c.used_at) and is_nil(c.cancelled_at),
        where: c.expires_at > ^now
    )
  end

  defp code_in_file(name), do: name |> CodeFile.path() |> File.read!() |> String.trim_trailing()

  # The node's enrolment with `code`, as it posts it.
  defp enrol(code) do
    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)
    encoded = Base.url_encode64(public, padding: false)
    now = System.os_time(:second)
    message = SignedMessage.enrolment(code, encoded, "machine", now)
    proof = :crypto.sign(:eddsa, :none, message, [secret, :ed25519])

    {:ok, request} =
      Enrolment.decode(
        Jason.encode!(%{
          "version" => 1,
          "code" => code,
          "name" => "machine",
          "public_key" => encoded,
          "timestamp" => now,
          "proof" => Ed25519.encode(proof)
        })
      )

    AccessKeys.enrol(request)
  end

  describe "the settings" do
    test "declare none unset or blank, and each node with its name and address" do
      assert boot(nil, " ", nil) == %{pool: nil, gateway: nil, url: nil}
      assert NodesInstalled.names() == []

      assert boot(" pool ", "gateway", "https://gateway.example:8443") ==
               %{pool: "pool", gateway: "gateway", url: "https://gateway.example:8443"}

      assert NodesInstalled.names() == ["pool", "gateway"]
      assert boot("pool", nil, nil).pool == "pool"
    end

    test "stop the boot on a malformed name or address, or one without the other" do
      for {pool, gateway, url, says} <- [
            {"Pool", nil, nil, "QORY_INSTALLED_POOL is not valid"},
            {nil, "gate_way", "https://gateway.example", "QORY_INSTALLED_GATEWAY is not valid"},
            {"same", "same", "https://gateway.example", "both name same"},
            {nil, "gateway", nil, "QORY_INSTALLED_GATEWAY_URL is not set"},
            {nil, nil, "https://gateway.example", "QORY_INSTALLED_GATEWAY is not"},
            {nil, "gateway", "http://gateway.example", "QORY_INSTALLED_GATEWAY_URL is not valid"},
            {nil, "gateway", "https://gateway.example/path", "QORY_INSTALLED_GATEWAY_URL is not"},
            {"tracker", nil, nil, "QORY_INSTALLED_ADAPTERS\nlists too"}
          ] do
        error = assert_raise ArgumentError, fn -> boot(pool, gateway, url) end
        assert error.message =~ says, inspect({pool, gateway, url})
      end
    end

    @tag with_features: [:observability, :security]
    test "stop the boot on a node declared where the instance has no node pools of its own" do
      error = assert_raise ArgumentError, fn -> boot("pool", nil, nil) end
      assert error.message =~ "declares a node of\nthe instance"
      refute error.message =~ "factory"
      assert boot(nil, nil, nil) == %{pool: nil, gateway: nil, url: nil}
    end
  end

  describe "a pass" do
    test "waits until the instance is set up, and writes no code before" do
      :ok = Apiary.Edition.put_test_stub(NotSetUp)
      assert Installer.pass() == :waiting
      assert Repo.all(from n in Node, where: n.kind in [:pool, :gateway]) == []
      refute CodeFile.exists?("pool")
      refute CodeFile.exists?("gateway")
    end

    test "makes the pool and the gateway once, and writes their codes to their folders",
         %{dir: dir} do
      assert Installer.pass() == {:ok, []}

      pool = declared_node(:pool)
      gateway = declared_node(:gateway)
      assert {pool.name, pool.installed_as, pool.organisation_id} == {"pool", "pool", nil}
      assert pool.gateway_choice == :default
      assert pool.instance_limit == nil
      assert {gateway.installed_as, gateway.url} == {"gateway", "https://gateway.example"}

      for node <- [pool, gateway] do
        assert [%Entry{actor_kind: :instance, workspace_id: nil}] = entries(:"node.install", node)
      end

      fingerprint = Regex.escape(Apiary.SigningKey.fingerprint())
      assert code_in_file("pool") =~ ~r/\Aqecp_[0-9A-Z]{26}\.#{fingerprint}\z/
      assert code_in_file("gateway") =~ ~r/\Aqecg_[0-9A-Z]{26}\.#{fingerprint}\z/
      assert Enum.sort(File.ls!(dir)) == ["gateway", "pool"]

      for name <- ["pool", "gateway"] do
        assert mode(CodeFile.path(name)) == 0o400
        assert mode(CodeFile.folder(name)) == 0o700
      end

      assert [%EnrolmentCode{allow_secrets: false, created_by_id: nil}] = outstanding(pool)
      assert [%EnrolmentCode{allow_secrets: true, created_by_id: nil}] = outstanding(gateway)

      # Again: the same nodes, the same codes, no entry.
      assert Installer.pass() == {:ok, []}
      assert Repo.aggregate(from(n in Node, where: n.kind in [:pool, :gateway]), :count) == 2
      assert length(outstanding(pool)) == 1
      assert length(entries(:"node.install", pool)) == 1
    end

    test "a node takes a changed name and address, and its old file goes" do
      assert Installer.pass() == {:ok, []}
      gateway = declared_node(:gateway)

      declare(%{pool: "pool", gateway: "edge", url: "https://edge.example"})
      assert Installer.pass() == {:ok, []}

      assert %Node{id: id, installed_as: "edge", url: "https://edge.example"} =
               declared_node(:gateway)

      assert id == gateway.id
      refute CodeFile.exists?("gateway")
      assert CodeFile.exists?("edge")
    end

    test "the file's code enrols the node with one key, and the file goes" do
      assert Installer.pass() == {:ok, []}
      gateway = declared_node(:gateway)

      assert {:ok, %AccessKey{allow_secrets: true, organisation_id: nil} = key} =
               enrol(code_in_file("gateway"))

      assert key.node_id == gateway.id
      refute CodeFile.exists?("gateway")

      assert {:ok, %AccessKey{allow_secrets: false}} = enrol(code_in_file("pool"))
      refute CodeFile.exists?("pool")

      # Enrolled: no new code, the outstanding ones cancelled.
      assert Installer.pass() == {:ok, []}
      refute CodeFile.exists?("gateway")
      assert outstanding(gateway) == []
    end

    test "a revoked key brings a nudge, and the pass a new code", %{admin: admin} do
      assert Installer.pass() == {:ok, []}
      pool = declared_node(:pool)
      assert {:ok, key} = enrol(code_in_file("pool"))
      assert Installer.pass() == {:ok, []}

      :ok = Phoenix.PubSub.subscribe(Apiary.PubSub, Installed.topic())
      assert {:ok, %AccessKey{revoked_at: %DateTime{}}} = Adapters.revoke_key(admin, key)
      assert_receive :nudge

      assert Installer.pass() == {:ok, []}
      assert CodeFile.exists?("pool")
      assert [_code] = outstanding(pool)
    end

    test "a person gets no code for a node declared", %{admin: admin} do
      assert Installer.pass() == {:ok, []}

      for kind <- [:pool, :gateway] do
        assert {:error, :installed} =
                 AccessKeys.create_enrolment_code(admin, declared_node(kind), %{})
      end
    end
  end

  describe "a node no longer declared" do
    test "has its codes cancelled and its file deleted, and stays" do
      assert Installer.pass() == {:ok, []}
      pool = declared_node(:pool)
      code = code_in_file("pool")

      declare(%{pool: nil, gateway: "gateway", url: "https://gateway.example"})
      assert Installer.pass() == {:ok, []}

      assert outstanding(pool) == []
      refute CodeFile.exists?("pool")
      assert Repo.reload!(pool).deleted_at == nil
      assert [%Entry{actor_kind: :instance}] = entries(:"access_key.cancel_code", pool)

      # Its code enrols nothing any more.
      assert {:error, :unauthorized} = enrol(code)
    end

    test "is not made when none is declared" do
      declare(%{pool: nil, gateway: nil, url: nil})
      assert Installer.pass() == {:ok, []}
      assert Repo.all(from n in Node, where: n.kind in [:pool, :gateway]) == []
    end
  end
end
