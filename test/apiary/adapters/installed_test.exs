defmodule Apiary.Adapters.InstalledTest do
  # The adapters installed with Qory Apiary: the setting that lists them and its checks at
  # boot (`Apiary.Adapters.Installed`), the folders made at boot, the file a code is written
  # to, in a folder per adapter (`CodeFile`), and the installer's pass
  # (`Apiary.Adapters.Installer.pass/0`) and process: the adapter made once for each
  # name, its code while it has no key, kept, renewed or made again, the entries it leaves
  # and those it does not, the enrolment with the file's code, the codes cancelled once a
  # key is live or the name is taken off, a revocation that brings a code at once, and the
  # refusals while a name is listed, and a pass that fails of any kind. Not async: the names
  # and the directory are the whole node's.
  use Apiary.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Adapters, Edition}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Adapters.{Installed, Installer}
  alias Apiary.Adapters.Installed.CodeFile
  alias Apiary.Audit.Entry
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}
  alias Apiary.Nodes.Node

  @moduletag needs: :factory
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    saved =
      for key <- [:installed_adapters, :installed_adapters_setting, :enrolment_dir_setting],
          do: {key, Application.fetch_env(:apiary, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, value} -> Application.put_env(:apiary, key, value)
          :error -> Application.delete_env(:apiary, key)
        end
      end
    end)

    Application.put_env(:apiary, :enrolment_dir_setting, dir)
    name = "tracker-#{System.unique_integer([:positive])}"
    list([name])

    %{dir: dir, name: name, scope: instance_scope(), admin: instance_admin_scope()}
  end

  defp list(names), do: Application.put_env(:apiary, :installed_adapters, names)

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  # An edition whose instance cannot be found: a pass exits before any name's.
  defmodule ExitsBeforeNames do
    def instance_organisation_id, do: exit(:stopped)
  end

  # An edition that exits when the instance installs an adapter: a name's pass exits.
  defmodule ExitsOnInstall do
    def check(_scope, :"adapter.install", _subject), do: exit(:stopped)
    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end

  # An edition that throws when the instance installs an adapter.
  defmodule ThrowsOnInstall do
    def check(_scope, :"adapter.install", _subject), do: throw(:stopped)
    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end

  defp installed(name),
    do: Repo.one!(from n in Node, where: n.installed_as == ^name and is_nil(n.deleted_at))

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

  defp file(name), do: File.read!(CodeFile.path(name))

  # The code as the file holds it, without its newline.
  defp code_in_file(name), do: name |> file() |> String.trim_trailing("\n")

  # Every outstanding code of the adapter with `seconds` left, as a renewal finds it.
  defp expire_in(adapter, seconds) do
    at = DateTime.add(DateTime.utc_now(), seconds, :second)

    for code <- outstanding(adapter) do
      code
      |> Ecto.Changeset.change(expires_at: at)
      |> EnrolmentCode.put_integrity()
      |> Repo.update!()
    end
  end

  defp pair do
    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)
    %{encoded: Base.url_encode64(public, padding: false), secret: secret}
  end

  # The adapter's enrolment with `code`, as it posts it.
  defp enrol(code, pair \\ pair()) do
    now = System.os_time(:second)
    message = SignedMessage.enrolment(code, pair.encoded, "tracker", now)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519])

    {:ok, request} =
      Enrolment.decode(
        Jason.encode!(%{
          "version" => 1,
          "code" => code,
          "name" => "tracker",
          "public_key" => pair.encoded,
          "timestamp" => now,
          "proof" => Ed25519.encode(proof)
        })
      )

    AccessKeys.enrol(request)
  end

  describe "the setting" do
    defp boot(value) do
      Application.put_env(:apiary, :installed_adapters_setting, value)
      Installed.boot!()
    end

    test "names none unset or blank, and the names listed, trimmed, in order" do
      assert boot(nil) == []
      assert boot("  ") == []
      assert boot(" tracker , wiki-2 ") == ["tracker", "wiki-2"]
      assert Installed.names() == ["tracker", "wiki-2"]
      assert Installed.listed?("wiki-2")
      refute Installed.listed?("wiki")
      refute Installed.listed?(nil)
    end

    test "stops the boot on a malformed name, an empty one or a name listed twice" do
      for value <- [
            "Tracker",
            "2tracker",
            "tracker_one",
            "tracker,,wiki",
            "tracker,",
            String.duplicate("a", 33)
          ] do
        error = assert_raise ArgumentError, fn -> boot(value) end
        assert error.message =~ "QORY_INSTALLED_ADAPTERS is not valid", value
      end

      error = assert_raise ArgumentError, fn -> boot("tracker,wiki,tracker") end
      assert error.message =~ "tracker is listed twice"
      assert boot(String.duplicate("a", 32)) == [String.duplicate("a", 32)]
    end

    @tag with_features: [:observability, :security]
    test "stops the boot on any name where the instance has no adapters, and not on none" do
      error = assert_raise ArgumentError, fn -> boot("tracker") end
      assert error.message =~ "QORY_INSTALLED_ADAPTERS names adapters"
      refute error.message =~ "factory"
      assert boot("") == []
    end

    test "the directory is the setting's, else /run/qory/enrolment", %{dir: dir} do
      assert Installed.dir() == dir
      Application.put_env(:apiary, :enrolment_dir_setting, " ")
      assert Installed.dir() == "/run/qory/enrolment"
      Application.delete_env(:apiary, :enrolment_dir_setting)
      assert Installed.dir() == "/run/qory/enrolment"
    end

    test "stops the boot on a directory that is not an absolute path, names listed or not" do
      for value <- ["enrolment", "./enrolment", "../run/qory", "~/enrolment"],
          names <- [nil, "tracker"] do
        Application.put_env(:apiary, :enrolment_dir_setting, value)
        error = assert_raise ArgumentError, fn -> boot(names) end

        assert error.message =~
                 "environment variable QORY_ENROLMENT_DIR is not valid: " <>
                   "#{inspect(value)} is not an absolute path.",
               value
      end

      for value <- [nil, "", " ", "/run/qory/enrolment", " /srv/enrolment "] do
        Application.put_env(:apiary, :enrolment_dir_setting, value)
        assert boot("tracker") == ["tracker"], inspect(value)
      end
    end
  end

  describe "the folders at boot" do
    test "are made for each name listed, 0755, and those there are kept", %{dir: dir} do
      list(["tracker", "wiki"])
      File.mkdir!(Path.join(dir, "wiki"))
      File.write!(Path.join([dir, "wiki", "code"]), "kept\n")

      assert Installed.make_folders() == :ok
      assert Enum.sort(File.ls!(dir)) == ["tracker", "wiki"]
      assert mode(Path.join(dir, "tracker")) == 0o755
      assert File.ls!(Path.join(dir, "tracker")) == []
      assert File.read!(Path.join([dir, "wiki", "code"])) == "kept\n"
    end

    test "one that cannot be made is said, the others made, and nothing stops", %{dir: dir} do
      list(["tracker", "wiki"])
      elsewhere = Path.join(dir, "elsewhere")
      File.mkdir!(elsewhere)
      File.ln_s!(elsewhere, Path.join(dir, "tracker"))

      log = capture_log(fn -> assert Installed.make_folders() == :ok end)

      assert log =~
               "could not make the folder of the installed adapter tracker, " <>
                 "#{Path.join(dir, "tracker")}: not a directory; " <>
                 "trying again when its one-time code is written"

      assert File.dir?(Path.join(dir, "wiki"))
      assert File.ls!(elsewhere) == []

      Application.put_env(:apiary, :enrolment_dir_setting, Path.join(dir, "missing"))
      log = capture_log(fn -> assert Installed.make_folders() == :ok end)
      assert log =~ "could not make the folder of the installed adapter wiki"
      assert log =~ "no such file or directory"
    end

    test "make none where no name is listed", %{dir: dir} do
      list([])
      assert Installed.make_folders() == :ok
      assert File.ls!(dir) == []
    end
  end

  describe "the code file" do
    test "is written whole, 0644, with one newline, in the adapter's folder, made 0755",
         %{dir: dir} do
      assert CodeFile.folder("tracker") == Path.join(dir, "tracker")
      assert CodeFile.path("tracker") == Path.join([dir, "tracker", "code"])

      assert CodeFile.write("tracker", "first") == :ok
      assert CodeFile.write("tracker", "second") == :ok
      assert File.read!(Path.join([dir, "tracker", "code"])) == "second\n"
      assert mode(Path.join([dir, "tracker", "code"])) == 0o644
      assert mode(Path.join(dir, "tracker")) == 0o755
      assert File.ls!(dir) == ["tracker"]
      assert File.ls!(Path.join(dir, "tracker")) == ["code"]
      assert CodeFile.exists?("tracker")
    end

    test "a write that fails leaves the old file and no temporary one", %{dir: dir} do
      assert CodeFile.write("tracker", "first") == :ok
      Application.put_env(:apiary, :enrolment_dir_setting, Path.join(dir, "missing"))
      assert {:error, :enoent} = CodeFile.write("tracker", "second")
      Application.put_env(:apiary, :enrolment_dir_setting, dir)
      assert File.ls!(dir) == ["tracker"]
      assert File.ls!(Path.join(dir, "tracker")) == ["code"]
      assert File.read!(Path.join([dir, "tracker", "code"])) == "first\n"
    end

    test "is refused where a symbolic link or a file is in the place of the folder",
         %{dir: dir} do
      elsewhere = Path.join(dir, "elsewhere")
      File.mkdir!(elsewhere)
      File.ln_s!(elsewhere, Path.join(dir, "tracker"))
      File.write!(Path.join(dir, "wiki"), "")

      assert CodeFile.write("tracker", "first") == {:error, :enotdir}
      assert CodeFile.write("wiki", "first") == {:error, :enotdir}
      assert File.ls!(elsewhere) == []
      assert File.read!(Path.join(dir, "wiki")) == ""
      refute CodeFile.exists?("tracker")
    end

    test "is deleted, a missing one too, and the folder stays", %{dir: dir} do
      assert CodeFile.write("tracker", "first") == :ok
      assert CodeFile.delete("tracker") == :ok
      refute CodeFile.exists?("tracker")
      assert File.ls!(Path.join(dir, "tracker")) == []
      assert CodeFile.delete("tracker") == :ok
      assert CodeFile.delete("wiki") == :ok
    end
  end

  describe "a pass" do
    test "installs each name once, by the instance, and writes its first code with its entry",
         %{name: name, dir: dir} do
      assert Installer.pass() == {:ok, []}

      adapter = installed(name)
      assert adapter.name == name
      assert adapter.created_by_id == nil
      assert adapter.organisation_id == nil

      assert [%Entry{actor_kind: :instance, after: %{"installed_as" => ^name}}] =
               entries(:"adapter.install", adapter)

      fingerprint = Apiary.SigningKey.fingerprint()
      assert file(name) =~ ~r/\Aqeci_[0-9A-Z]{26}\.#{Regex.escape(fingerprint)}\n\z/
      assert mode(CodeFile.path(name)) == 0o644
      assert File.ls!(dir) == [name]
      assert File.ls!(Path.join(dir, name)) == ["code"]

      [head, _fingerprint] = String.split(code_in_file(name), ".", parts: 2)
      assert [%EnrolmentCode{created_by_id: nil} = row] = outstanding(adapter)
      assert row.code_sha256 == EnrolmentCode.hash(head)
      refute row.allow_secrets

      assert [%Entry{actor_kind: :instance} = entry] = entries(:"access_key.create_code", adapter)
      assert entry.details == %{"installed" => true}
      assert entry.after["code_id"] == row.id
      refute inspect(Map.from_struct(entry)) =~ head

      # Again: the same adapter, the same code, no entry.
      assert Installer.pass() == {:ok, []}
      assert Repo.aggregate(from(n in Node, where: n.installed_as == ^name), :count) == 1
      assert [%EnrolmentCode{id: id}] = outstanding(adapter)
      assert id == row.id
      assert code_in_file(name) == head <> "." <> fingerprint
      assert length(entries(:"access_key.create_code", adapter)) == 1
      assert length(entries(:"adapter.install", adapter)) == 1
    end

    test "renews a code with 300 seconds left or fewer, and records no entry for it",
         %{name: name} do
      assert Installer.pass() == {:ok, []}
      adapter = installed(name)
      first = file(name)

      expire_in(adapter, 299)
      assert Installer.pass() == {:ok, []}

      assert file(name) != first
      assert length(outstanding(adapter)) == 2
      assert length(entries(:"access_key.create_code", adapter)) == 1
    end

    test "makes a new code without an entry when the file is gone and the code still valid",
         %{name: name} do
      assert Installer.pass() == {:ok, []}
      adapter = installed(name)
      File.rm!(CodeFile.path(name))

      assert Installer.pass() == {:ok, []}
      assert CodeFile.exists?(name)
      assert length(outstanding(adapter)) == 2
      assert length(entries(:"access_key.create_code", adapter)) == 1
    end

    test "records the first code again once the codes it had ran out", %{name: name} do
      assert Installer.pass() == {:ok, []}
      adapter = installed(name)
      expire_in(adapter, -1)

      assert Installer.pass() == {:ok, []}
      assert length(outstanding(adapter)) == 1
      assert length(entries(:"access_key.create_code", adapter)) == 2
    end

    test "names the adapter -2, -3 where its name is taken", %{name: name} do
      adapter_fixture(%{name: name})
      adapter_fixture(%{name: name <> "-2"})

      assert Installer.pass() == {:ok, []}
      assert installed(name).name == name <> "-3"
    end

    test "says a write that fails, keeps no code and no entry, and logs no code",
         %{name: name, dir: dir} do
      Application.put_env(:apiary, :enrolment_dir_setting, Path.join(dir, "missing"))

      assert Installer.pass() == {:ok, [{name, {:code_file, :enoent}}]}
      adapter = installed(name)
      assert outstanding(adapter) == []
      assert entries(:"access_key.create_code", adapter) == []

      line = Installer.failure_line(name, {:code_file, :enoent})

      assert line ==
               "could not write the one-time code of the installed adapter #{name} to " <>
                 "#{Path.join([dir, "missing", name])}: no such file or directory; trying again"

      refute line =~ "qeci_"
    end

    test "says a symbolic link in the place of the folder, and writes nothing through it",
         %{name: name, dir: dir} do
      elsewhere = Path.join(dir, "elsewhere")
      File.mkdir!(elsewhere)
      File.ln_s!(elsewhere, Path.join(dir, name))

      assert Installer.pass() == {:ok, [{name, {:code_file, :enotdir}}]}
      assert outstanding(installed(name)) == []
      assert File.ls!(elsewhere) == []

      assert Installer.failure_line(name, {:code_file, :enotdir}) =~
               "could not write the one-time code of the installed adapter #{name} to " <>
                 "#{Path.join(dir, name)}: not a directory; trying again"
    end

    test "a name's pass that exits or throws is the name's failure, with its kind alone",
         %{name: name} do
      Edition.put_test_stub(ExitsOnInstall)
      assert Installer.pass() == {:ok, [{name, {:caught, :exit}}]}
      Edition.put_test_stub(ThrowsOnInstall)
      assert Installer.pass() == {:ok, [{name, {:caught, :throw}}]}

      assert Installer.failure_line(name, {:caught, :exit}) ==
               "could not install the adapter #{name}: :exit; trying again"
    end

    test "logs no code", %{name: name} do
      log = capture_log([level: :debug], fn -> assert Installer.pass() == {:ok, []} end)
      refute log =~ ~r/qeci_/i
      refute log =~ code_in_file(name)
    end

    @tag with_features: [:observability, :security]
    test "does nothing where the instance has no adapters" do
      assert Installer.pass() == :off
    end
  end

  describe "the installer's process" do
    # The process, started here, then given `stub` in its process dictionary and asked to pass.
    # A wait for a pass has no limit but the test's timeout: a pass writes to the database
    # and syncs the code file, which on a loaded machine can take longer than the 5 seconds
    # `:sys.get_state/1` waits by default.
    defp pass_in_process(stub) do
      pid = start_supervised!(Installer)
      ref = Process.monitor(pid)
      # The first pass, which `init/1` asks for, done before the stub is put.
      _state = :sys.get_state(pid, :infinity)

      log =
        capture_log(fn ->
          :sys.replace_state(pid, fn state ->
            :ok = Edition.put_test_stub(stub)
            state
          end)

          send(pid, :pass)
          _state = :sys.get_state(pid, :infinity)
        end)

      {pid, ref, log}
    end

    test "stays up when a whole pass exits, and says its kind alone" do
      {pid, ref, log} = pass_in_process(ExitsBeforeNames)

      assert Process.alive?(pid)
      refute_received {:DOWN, ^ref, :process, ^pid, _reason}
      assert log =~ "could not install the adapters: :exit; trying again"
      refute log =~ "stopped"
    end

    test "stays up when a name's pass exits, and says its kind alone", %{name: name} do
      {pid, ref, log} = pass_in_process(ExitsOnInstall)

      assert Process.alive?(pid)
      refute_received {:DOWN, ^ref, :process, ^pid, _reason}
      assert log =~ "could not install the adapter #{name}: :exit; trying again"
      refute log =~ "stopped"
    end
  end

  describe "the key" do
    test "the file's code enrols the one key, by itself, and the file goes", %{name: name} do
      assert Installer.pass() == {:ok, []}
      adapter = installed(name)

      assert {:ok, %AccessKey{} = key} = enrol(code_in_file(name))
      assert key.created_by_id == nil
      assert key.arrived_by == :code
      refute CodeFile.exists?(name)
      assert AccessKeys.active_key?(adapter)
    end

    test "is one at most: a second enrolment is refused", %{name: name} do
      assert Installer.pass() == {:ok, []}
      adapter = installed(name)
      first = code_in_file(name)
      expire_in(adapter, 100)
      assert Installer.pass() == {:ok, []}
      second = code_in_file(name)
      assert first != second

      assert {:ok, %AccessKey{}} = enrol(second)
      assert {:error, :key_limit} = enrol(first)
    end

    test "once it is live, the pass cancels the codes left, each with its entry, and writes none",
         %{name: name} do
      assert Installer.pass() == {:ok, []}
      adapter = installed(name)
      expire_in(adapter, 100)
      assert Installer.pass() == {:ok, []}
      assert {:ok, %AccessKey{}} = enrol(code_in_file(name))

      assert Installer.pass() == {:ok, []}
      assert outstanding(adapter) == []
      refute CodeFile.exists?(name)

      assert [%Entry{actor_kind: :instance, details: %{"code_id" => _}}] =
               entries(:"access_key.cancel_code", adapter)

      assert length(entries(:"access_key.create_code", adapter)) == 1
    end

    test "revoked, the last one brings a nudge, and the pass a code with its entry",
         %{name: name, admin: admin} do
      assert Installer.pass() == {:ok, []}
      adapter = installed(name)
      assert {:ok, key} = enrol(code_in_file(name))
      assert Installer.pass() == {:ok, []}

      :ok = Phoenix.PubSub.subscribe(Apiary.PubSub, Installed.topic())
      assert {:ok, %AccessKey{revoked_at: %DateTime{}}} = Adapters.revoke_key(admin, key)
      assert_receive :nudge

      assert Installer.pass() == {:ok, []}
      assert CodeFile.exists?(name)
      assert [_code] = outstanding(adapter)
      assert length(entries(:"access_key.create_code", adapter)) == 2
    end
  end

  describe "while listed" do
    test "a person gets no code for it, and does not remove it", %{name: name, admin: admin} do
      assert Installer.pass() == {:ok, []}
      adapter = installed(name)

      assert {:error, :installed} = AccessKeys.create_enrolment_code(admin, adapter, %{})
      assert {:error, :installed} = Adapters.create_code(admin, adapter)
      assert {:error, :installed} = Adapters.delete_adapter(admin, adapter)
      assert Repo.reload!(adapter).deleted_at == nil
      assert Adapters.listed?(adapter)
    end
  end

  describe "a name taken off the list" do
    test "cancels its codes with their entries and deletes its file, and keeps the adapter",
         %{name: name, admin: admin} do
      assert Installer.pass() == {:ok, []}
      adapter = installed(name)
      code = code_in_file(name)

      list([])
      assert Installer.pass() == {:ok, []}

      assert outstanding(adapter) == []
      refute CodeFile.exists?(name)
      assert Repo.reload!(adapter).deleted_at == nil
      assert [%Entry{actor_kind: :instance}] = entries(:"access_key.cancel_code", adapter)
      assert {:error, :unauthorized} = enrol(code)

      refute Adapters.listed?(adapter)
      assert {:ok, %Node{deleted_at: %DateTime{}}} = Adapters.delete_adapter(admin, adapter)
    end

    test "its code no longer enrols, even before a pass cancels it", %{name: name} do
      assert Installer.pass() == {:ok, []}
      code = code_in_file(name)
      list([])
      assert {:error, :unauthorized} = enrol(code)
      list([name])
      assert {:ok, %AccessKey{}} = enrol(code)
    end

    test "listed again, the adapter in use is found again; once removed, a new one is made",
         %{name: name, admin: admin} do
      assert Installer.pass() == {:ok, []}
      adapter = installed(name)
      list([])
      assert Installer.pass() == {:ok, []}
      list([name])
      assert Installer.pass() == {:ok, []}
      assert installed(name).id == adapter.id

      list([])
      assert {:ok, _deleted} = Adapters.delete_adapter(admin, adapter)
      list([name])
      assert Installer.pass() == {:ok, []}
      refute installed(name).id == adapter.id
    end
  end

  describe "who may" do
    test "only the instance installs and gives codes", %{admin: admin, scope: scope, name: name} do
      assert {:error, :forbidden} = Adapters.install(admin, name)
      assert {:error, :invalid} = Adapters.install(scope, "Not a name")
      assert {:ok, adapter} = Adapters.install(scope, name)
      assert {:error, :forbidden} = AccessKeys.issue_installed_code(admin, adapter)
      assert {:error, :forbidden} = AccessKeys.cancel_installed_codes(admin, adapter)

      %{scope: other} = sign_up_fixture()

      assert {:error, :forbidden} =
               Adapters.install(Apiary.Accounts.Scope.for_instance(other.organisation), name)
    end
  end
end
