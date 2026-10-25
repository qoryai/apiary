defmodule Apiary.SetupTest do
  @moduledoc """
  The set-up link (`Apiary.Setup`): the code found or made at a start before set-up and
  logged in the one line, the set-up that uses it, and the refusal of every other sign-up
  before it. The suite's instance is set up (`ensure_instance_organisation!/0`); a test of
  an instance before set-up hides its organisation inside its sandbox
  (`Apiary.EditionKit`). Two at once, each on a connection of its own, are in
  `Apiary.SignUpRacesTest`.
  """
  # Not async: the tests hide the suite's instance organisation, a row every test shares,
  # and read the instance's own settings row.
  use Apiary.DataCase, async: false

  import ExUnit.CaptureLog
  import Apiary.AccountsFixtures

  alias Apiary.{Access, Organisations, Setup}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Membership, Organisation, Workspace}

  defp count(schema), do: Repo.aggregate(schema, :count)

  # What the instance's own row holds of its set-up: `{setup_code, set_up_at}`, nil when
  # there is no row.
  defp stored do
    case Repo.query!("SELECT setup_code, set_up_at FROM instance_settings WHERE id") do
      %{rows: [[code, at]]} -> {code, at}
      %{rows: []} -> nil
    end
  end

  # The used preset in the instance's row, `used_setup_code_sha256`; nil when there is no
  # row.
  defp used do
    case Repo.query!("SELECT used_setup_code_sha256 FROM instance_settings WHERE id") do
      %{rows: [[used]]} -> used
      %{rows: []} -> nil
    end
  end

  # `details.setup_code` of the entry that begins the trail of the organisation `id`.
  defp setup_code_detail(id) do
    [entry] =
      Repo.all(
        from e in Entry, where: e.organisation_id == ^id and e.action == "organisation.create"
      )

    entry.details["setup_code"]
  end

  # A code of the form Qory Apiary makes, as an install makes it.
  defp new_code, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp sha256(code), do: :crypto.hash(:sha256, code)

  # QORY_SETUP_CODE_SHA256 set to `setting` for this test.
  defp put_preset_setting(setting) do
    previous = Application.get_env(:apiary, Setup, [])

    Application.put_env(
      :apiary,
      Setup,
      Keyword.put(previous, :preset_code_sha256_setting, setting)
    )

    on_exit(fn -> Application.put_env(:apiary, Setup, previous) end)
  end

  # QORY_SETUP_CODE_SHA256 set to the hash of `code`, as `sha256sum` prints it.
  defp put_preset(code), do: put_preset_setting(Base.encode16(sha256(code), case: :lower))

  # The boot's step, as the application's supervisor starts it, with what it logged at
  # info and up; the suite logs warnings and up.
  defp boot do
    level = Logger.level()
    Logger.configure(level: :info)

    try do
      log =
        capture_log([level: :info], fn ->
          send(self(), {:boot, Setup.start_link()})
        end)

      assert_received {:boot, result}
      {result, log}
    after
      Logger.configure(level: level)
    end
  end

  # The calls this process makes of `mfa` while `fun` runs, each its arguments, in order,
  # gathered by a tracer of their own: a process cannot trace itself.
  defp traced({module, function, _arity} = mfa, fun) do
    tracer = spawn_link(fn -> gather([]) end)
    :erlang.trace_pattern(mfa, true, [:global])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern(mfa, false, [:global])
    end

    # Every trace message on its way to the tracer before it is asked.
    ref = :erlang.trace_delivered(self())

    receive do
      {:trace_delivered, _pid, ^ref} -> :ok
    end

    send(tracer, {:calls, self()})

    receive do
      {:calls, calls} -> for {^module, ^function, args} <- calls, do: args
    end
  end

  defp gather(calls) do
    receive do
      {:trace, _pid, :call, call} -> gather([call | calls])
      {:calls, to} -> send(to, {:calls, Enum.reverse(calls)})
    end
  end

  defp attrs(extra \\ %{}) do
    Enum.into(extra, %{email: unique_user_email(), organisation_name: "Acme Hosting"})
  end

  defp password_attrs(extra \\ %{}) do
    attrs(
      Enum.into(extra, %{
        password: valid_user_password(),
        password_confirmation: valid_user_password()
      })
    )
  end

  test "starts after the edition's processes and just before the endpoint, once" do
    previous = Application.get_env(:apiary, Setup)
    Application.put_env(:apiary, Setup, enabled: true)
    on_exit(fn -> Application.put_env(:apiary, Setup, previous) end)

    children = Apiary.Application.children()
    at = &Enum.find_index(children, fn child -> child == &1 end)

    assert at.(Apiary.Repo) < at.(Setup)
    assert at.(Setup) == at.(ApiaryWeb.Endpoint) - 1

    assert %{restart: :temporary, start: {Setup, :start_link, []}} = Setup.child_spec([])
  end

  test "is off in test, where the tests call it" do
    refute Setup.enabled?()
    refute Setup in Apiary.Application.children()
  end

  describe "before set-up" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    test "the first start stores a code, and logs the link with it in one line" do
      Repo.query!("DELETE FROM instance_settings")

      assert {:ignore, log} = boot()
      assert {code, nil} = stored()

      # 32 random bytes, in base64url without padding.
      assert code =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert byte_size(Base.url_decode64!(code, padding: false)) == 32

      # One line, and one only, carries the code.
      assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ code))
      assert line =~ "[info]"

      assert line |> String.split("[info] ", parts: 2) |> List.last() ==
               "Set up Qory Apiary at #{ApiaryWeb.Endpoint.url()}/setup/#{code}."

      assert Setup.link(code) == "#{ApiaryWeb.Endpoint.url()}/setup/#{code}"
    end

    test "a later start, and code!/0, find the same code, and log the same link" do
      code = Setup.code!()
      assert Setup.code!() == code

      assert {:ignore, log} = boot()
      assert log =~ Setup.log_line(code)
      assert {^code, nil} = stored()
    end

    test "a code is made where the row has none, and a set_up_at left is cleared" do
      Repo.query!("UPDATE instance_settings SET setup_code = NULL, set_up_at = now()")

      code = Setup.code!()
      assert {^code, nil} = stored()
    end

    test "the address is the configured one when the endpoint does not run, as Phoenix builds it" do
      # Development's default: no scheme or port in url:, the server on http port 4100.
      assert Setup.configured_url(url: [host: "localhost"], http: [port: 4100]) ==
               "http://localhost:4100"

      assert Setup.configured_url(url: [host: "localhost"], http: [port: "4100"]) ==
               "http://localhost:4100"

      # Behind a proxy: url: names the public scheme and port, whatever the server's.
      assert Setup.configured_url(
               url: [host: "qory.example.com", scheme: "https", port: 443],
               http: [port: 4000]
             ) == "https://qory.example.com"

      assert Setup.configured_url(url: [host: "qory.example.com"], https: [port: 8443]) ==
               "https://qory.example.com:8443"

      assert Setup.configured_url(url: [host: "example.com"]) == "http://example.com"

      # The same address the running endpoint gives, from the suite's configuration.
      assert Setup.configured_url(Application.get_env(:apiary, ApiaryWeb.Endpoint)) ==
               ApiaryWeb.Endpoint.url()
    end

    test "both comparisons of a code are made in constant time" do
      code = Setup.code!()
      sent = String.duplicate("A", 43)

      calls =
        traced({Plug.Crypto, :secure_compare, 2}, fn ->
          refute Setup.valid_code?(sent)
          assert Setup.valid_code?(code)
          assert {:ok, _signed_up} = Setup.set_up(code, password_attrs())
        end)

      # valid_code?/1 twice, then set_up/3's own look and its check under the lock.
      assert calls == [[code, sent], [code, code], [code, code], [code, code]]
    end

    test "nobody signs up: sign_up_offer/1 says so, and sign_up_user/3 refuses" do
      before = {count(Organisation), count(User)}

      for open <- [false, true] do
        assert Organisations.sign_up_offer(open: open) == :not_set_up
        assert {:error, :not_set_up} = Organisations.sign_up_user(attrs(), nil, open: open)

        assert {:error, :not_set_up} =
                 Organisations.sign_up_user(password_attrs(), nil, open: open, first_only: true)
      end

      refute Organisations.sign_up_offered?()
      assert {count(Organisation), count(User)} == before
    end

    test "set_up/2 with the code makes the instance's organisation, Main and its admin" do
      code = Setup.code!()
      before = {count(Organisation), count(Workspace), count(Membership)}

      assert {:ok,
              %{user: user, organisation: organisation, workspace: workspace, membership: owner}} =
               Setup.set_up(code, password_attrs(email: "first@example.com"))

      assert %Organisation{name: "Acme Hosting"} = organisation
      assert Apiary.Edition.instance_organisation_id() == organisation.id
      assert %Workspace{name: "Main"} = workspace
      assert %Membership{level: :owner} = owner
      assert owner.user_id == user.id
      assert Access.instance_admin?(Scope.for_user(user))
      assert is_binary(user.hashed_password)
      assert user.email == "first@example.com"

      {organisations, workspaces, memberships} = before
      assert count(Organisation) == organisations + 1
      assert count(Workspace) == workspaces + 1
      assert count(Membership) == memberships + 1

      # The code dies on use.
      assert {nil, %NaiveDateTime{}} = stored()
      refute Setup.valid_code?(code)
      assert Setup.set_up?()

      # By the instance, from the set-up, as a first sign-up's entry is.
      assert [entry] =
               Repo.all(
                 from e in Entry,
                   where:
                     e.organisation_id == ^organisation.id and e.action == "organisation.create"
               )

      assert {entry.actor_kind, entry.actor_id} == {:instance, nil}
      assert entry.worker == "Apiary.Setup"
      assert entry.details["sign_up"] == true
      assert entry.details["setup_code"] == "link"
      assert entry.details["user_id"] == user.id
      refute inspect(entry) =~ code

      # After it, a sign-up is a later one.
      assert Organisations.sign_up_offer(open: false) == :closed
      assert Organisations.sign_up_offer(open: true) == :open
    end

    test "set_up/3 records the origin it is given" do
      origin = %{remote_ip: "203.0.113.7", user_agent: "test"}

      assert {:ok, %{organisation: organisation}} =
               Setup.set_up(Setup.code!(), password_attrs(), origin: origin)

      assert [entry] =
               Repo.all(
                 from e in Entry,
                   where:
                     e.organisation_id == ^organisation.id and e.action == "organisation.create"
               )

      assert entry.remote_ip == "203.0.113.7"
    end

    test "a wrong code sets nothing up, and the code stays" do
      code = Setup.code!()
      before = {count(Organisation), count(User)}

      <<first, rest::binary>> = code
      one_off = <<if(first == ?x, do: ?y, else: ?x), rest::binary>>

      for wrong <- ["", "short", String.duplicate("A", 43), one_off, code <> "A"] do
        refute Setup.valid_code?(wrong)
        assert Setup.set_up(wrong, password_attrs()) == {:error, :invalid_code}
      end

      assert {count(Organisation), count(User)} == before
      assert {^code, nil} = stored()
      refute Setup.set_up?()
    end

    test "the code is checked again inside the transaction, under the row's lock" do
      code = Setup.code!()

      assert Organisations.sign_up_user(password_attrs(), nil,
               first_only: true,
               actor: :instance,
               setup_code: String.duplicate("A", 43)
             ) == {:error, :invalid_code}

      assert {^code, nil} = stored()
      refute Setup.set_up?()
    end

    test "a code used twice sets up once" do
      code = Setup.code!()
      assert {:ok, _signed_up} = Setup.set_up(code, password_attrs())
      users = count(User)

      assert Setup.set_up(code, password_attrs()) == {:error, :already_set_up}
      assert count(User) == users
    end

    test "without mail, set_up/2 asks for a password; the page's password: :required always" do
      Apiary.Mail.put_test_source(:none)
      code = Setup.code!()

      assert {:error, changeset} = Setup.set_up(code, attrs())
      assert %{password: [_required | _]} = errors_on(changeset)

      Apiary.Mail.put_test_source(:env)
      assert {:error, changeset} = Setup.set_up(code, attrs(), password: :required)
      assert %{password: [_required | _]} = errors_on(changeset)

      assert {:error, changeset} =
               Setup.set_up(code, password_attrs(password_confirmation: "something else!"),
                 password: :required
               )

      assert %{password_confirmation: [_mismatch]} = errors_on(changeset)
      assert {^code, nil} = stored()
    end

    test "with mail, set_up/2 makes an account without a password when given none" do
      Apiary.Mail.put_test_source(:env)
      assert {:ok, %{user: user}} = Setup.set_up(Setup.code!(), attrs())
      assert is_nil(user.hashed_password)
    end

    test "with mail, a password given to set_up/2 is kept" do
      Apiary.Mail.put_test_source(:env)
      assert {:ok, %{user: user}} = Setup.set_up(Setup.code!(), password_attrs())
      assert Apiary.Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "a refused name or address leaves the code as it was" do
      code = Setup.code!()

      assert {:error, changeset} =
               Setup.set_up(code, password_attrs(email: "not an address", organisation_name: ""))

      assert %{email: [_ | _], organisation_name: [_ | _]} = errors_on(changeset)
      assert {^code, nil} = stored()
    end

    test "the release command's claim marks the code used" do
      code = Setup.code!()

      assert {:ok, :created} =
               ExUnit.CaptureIO.with_io(fn ->
                 Apiary.Release.grant_instance_admin("claim@example.com", "Acme")
               end)
               |> elem(0)

      assert {nil, %NaiveDateTime{}} = stored()
      assert Setup.set_up(code, password_attrs()) == {:error, :already_set_up}
      assert used() == nil
      assert setup_code_detail(Apiary.Edition.instance_organisation_id()) == "command"
    end
  end

  describe "once set up" do
    test "a start finds, makes and logs nothing" do
      before = stored()
      assert {:ignore, log} = boot()
      refute log =~ "Set up Qory Apiary"
      assert stored() == before
    end

    test "a restored instance, with no settings row, makes none" do
      Repo.query!("DELETE FROM instance_settings")
      assert {:ignore, log} = boot()
      refute log =~ "/setup/"
      assert stored() == nil
    end

    test "code!/0 raises, and set_up/2 says it is set up" do
      assert_raise ArgumentError, ~r/set up already/, fn -> Setup.code!() end
      assert Setup.set_up("any", password_attrs()) == {:error, :already_set_up}
      refute Setup.valid_code?("any")
    end
  end

  describe "QORY_SETUP_CODE_SHA256" do
    test "unset, blank or 64 hexadecimal characters in either case is read; spaces are trimmed" do
      code = new_code()
      hash = sha256(code)
      hex = Base.encode16(hash, case: :lower)

      for {setting, preset} <- [
            {nil, nil},
            {"", nil},
            {"  \n", nil},
            {hex, hash},
            {String.upcase(hex), hash},
            {" #{hex}\n", hash}
          ] do
        put_preset_setting(setting)
        assert Setup.preset!() == preset
      end
    end

    test "any other value stops the boot, with a message that starts with the fix and does not contain the value" do
      hex = Base.encode16(sha256(new_code()), case: :lower)

      for setting <- [
            binary_part(hex, 0, 63),
            hex <> "a",
            String.duplicate("g", 64),
            "sha256=" <> hex,
            Base.encode64(sha256(new_code()))
          ] do
        put_preset_setting(setting)
        error = assert_raise ArgumentError, fn -> Setup.preset!() end

        assert error.message ==
                 "Set QORY_SETUP_CODE_SHA256 to 64 hexadecimal characters, the SHA-256 of the " <>
                   "set-up code, or leave it unset. The value set is not that."

        refute error.message =~ setting
        refute inspect(error) =~ setting
      end
    end
  end

  describe "with a preset code, before set-up" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    test "a start stores no code, sets a stored one to NULL, and logs a line without a link" do
      # A code a start without the preset stored and logged.
      earlier = Setup.code!()
      code = new_code()
      put_preset(code)

      assert {:ignore, log} = boot()
      assert {nil, nil} = stored()
      refute Setup.valid_code?(earlier)
      assert Setup.set_up(earlier, password_attrs()) == {:error, :invalid_code}

      assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "Qory Apiary"))
      assert line =~ "[info]"

      assert line |> String.split("[info] ", parts: 2) |> List.last() ==
               "Qory Apiary is not set up yet. Open the set-up link that your install " <>
                 "printed; this log does not show it."

      refute log =~ "/setup/"
      assert_raise ArgumentError, ~r/preset set-up code/, fn -> Setup.code!() end
    end

    test "the code sets the instance up once; any other code sets nothing up" do
      code = new_code()
      put_preset(code)
      before = {count(Organisation), count(User)}

      <<first, rest::binary>> = code
      one_off = <<if(first == ?x, do: ?y, else: ?x), rest::binary>>
      hex = Base.encode16(sha256(code), case: :lower)

      for wrong <- ["", "short", new_code(), one_off, code <> "A", hex, sha256(code)] do
        refute Setup.valid_code?(wrong)
        assert Setup.set_up(wrong, password_attrs()) == {:error, :invalid_code}
      end

      assert {count(Organisation), count(User)} == before
      assert used() == nil

      assert Setup.valid_code?(code)
      assert {:ok, %{organisation: organisation}} = Setup.set_up(code, password_attrs())
      assert Apiary.Edition.instance_organisation_id() == organisation.id
      assert {nil, %NaiveDateTime{}} = stored()
      assert used() == sha256(code)
      assert setup_code_detail(organisation.id) == "preset"

      assert Setup.set_up(code, password_attrs()) == {:error, :already_set_up}
      refute Setup.valid_code?(code)
    end

    test "the release command's claim sets the instance up and marks the preset used" do
      code = new_code()
      put_preset(code)

      assert {:ok, :created} =
               ExUnit.CaptureIO.with_io(fn ->
                 Apiary.Release.grant_instance_admin("claim@example.com", "Acme")
               end)
               |> elem(0)

      assert {nil, %NaiveDateTime{}} = stored()
      assert used() == sha256(code)
      assert setup_code_detail(Apiary.Edition.instance_organisation_id()) == "command"
      assert Setup.set_up(code, password_attrs()) == {:error, :already_set_up}

      # After a purge of the instance's organisation, the preset is used.
      Apiary.EditionKit.hide_instance_organisation()
      refute Setup.valid_code?(code)
      assert Setup.set_up(code, password_attrs()) == {:error, :invalid_code}
    end

    test "a code is hashed only in the form Qory Apiary makes, and the digests are compared in constant time" do
      code = new_code()
      put_preset(code)
      preset = sha256(code)

      assert traced({:crypto, :hash, 2}, fn ->
               for wrong <- ["", "short", code <> "A", String.duplicate("!", 43)] do
                 refute Setup.valid_code?(wrong)
               end
             end) == []

      calls =
        traced({Plug.Crypto, :secure_compare, 2}, fn ->
          refute Setup.valid_code?(new_code())
          assert Setup.valid_code?(code)
        end)

      assert [[wrong_digest, ^preset], [^preset, ^preset]] = calls
      assert byte_size(wrong_digest) == 32
    end

    test "the code is checked again inside the transaction, under the row's lock" do
      code = new_code()
      put_preset(code)

      assert Organisations.sign_up_user(password_attrs(), nil,
               first_only: true,
               actor: :instance,
               setup_code: new_code()
             ) == {:error, :invalid_code}

      assert used() == nil
      refute Setup.set_up?()
    end

    test "after a purge, the same code is refused, and a start says a new one is needed" do
      code = new_code()
      put_preset(code)
      assert {:ok, _signed_up} = Setup.set_up(code, password_attrs())

      # The instance's organisation purged: its set_up_at and the used preset stay.
      Apiary.EditionKit.hide_instance_organisation()

      refute Setup.valid_code?(code)
      assert Setup.set_up(code, password_attrs()) == {:error, :invalid_code}

      assert {:ignore, log} = boot()
      assert {nil, %NaiveDateTime{}} = stored()
      assert used() == sha256(code)

      assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "QORY_SETUP_CODE_SHA256"))
      assert line =~ "[warning]"

      assert line |> String.split("[warning] ", parts: 2) |> List.last() ==
               "Set QORY_SETUP_CODE_SHA256 to the hash of a new set-up code, or unset it to " <>
                 "get a set-up link in this log. The code it gives has set up this instance before."

      refute log =~ "/setup/"
      refute log =~ "not set up yet"
    end

    test "no log line contains the code or its hash, not even the query log's debug lines" do
      code = new_code()
      hash = sha256(code)
      put_preset(code)

      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log([level: :debug], fn ->
          assert :ignore = Setup.start_link()
          assert Setup.valid_code?(code)
          assert {:ok, _signed_up} = Setup.set_up(code, password_attrs())
          assert Setup.set_up(code, password_attrs()) == {:error, :already_set_up}
          Apiary.EditionKit.hide_instance_organisation()
          refute Setup.valid_code?(code)
          assert :ignore = Setup.start_link()
        end)

      Logger.configure(level: level)

      # The log has the lines, at debug the queries among them.
      assert log =~ "not set up yet"
      assert log =~ "has set up this instance before"
      assert log =~ "instance_settings"

      for secret <- [
            code,
            Base.encode16(hash, case: :lower),
            Base.encode16(hash, case: :upper),
            Base.encode64(hash),
            Base.url_encode64(hash, padding: false),
            inspect(hash)
          ] do
        refute log =~ secret
      end
    end
  end

  describe "the code in the log" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    test "only the set-up line carries it, even in the query log's debug lines" do
      Repo.query!("UPDATE instance_settings SET setup_code = NULL")

      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log([level: :debug], fn ->
          code = Setup.code!()
          assert Setup.code!() == code
          assert :ignore = Setup.start_link()
          assert Setup.valid_code?(code)
          assert {:ok, _signed_up} = Setup.set_up(code, password_attrs())
          assert Setup.set_up(code, password_attrs()) == {:error, :already_set_up}
          send(self(), {:code, code})
        end)

      Logger.configure(level: level)
      assert_received {:code, code}

      # One line, and one only, carries the code.
      assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ code))
      assert line =~ Setup.log_line(code)
    end
  end

  test "first_sign_up_line/0 is the core's line" do
    assert Apiary.Edition.Core.first_sign_up_line() ==
             "Your organisation and its first workspace."
  end
end
