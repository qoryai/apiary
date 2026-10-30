defmodule Apiary.MailSettingsTest do
  @moduledoc """
  The mail settings an instance admin saves in Instance settings › Mail (`Apiary.Mail`):
  the save, the password kept encrypted, the test link that turns mail on for the admin
  who saved and for no one else, where mail then comes from, and each node's copy of the
  settings (`Apiary.Mail.Cache`).
  """
  # Not async: hiding the instance's organisation acts on the row every test shares, and
  # the mailer's environment, the features and the keys are the whole node's.
  use Apiary.DataCase, async: false

  import ExUnit.CaptureLog
  import Apiary.OrganisationsFixtures

  alias Apiary.{KeyDerivation, Mail}
  alias ApiaryWeb.Activity.Describer.Core, as: Describer
  alias Apiary.Accounts.{User, UserToken}
  alias Apiary.Mail.{Cache, Password, Settings}

  @password "correct horse battery staple"

  # An adapter that hands the test what it was asked to send, and how.
  defmodule Capture do
    @moduledoc false
    use Swoosh.Adapter

    def deliver(email, config) do
      for pid <- Enum.uniq([self() | List.wrap(Process.get(:"$callers"))]),
          do: send(pid, {:sent, email, config})

      {:ok, %{}}
    end
  end

  # An adapter whose relay refuses every email, as `Swoosh.Adapters.SMTP` returns it.
  defmodule Refusing do
    @moduledoc false
    use Swoosh.Adapter

    def deliver(_email, _config),
      do: {:error, {:send, {:permanent_failure, ~c"smtp.example.com", "550 refused\r\n"}}}
  end

  # An adapter that answers what the test put as `{:answer, answer, traces}`, as
  # `Swoosh.Adapters.SMTP` answers for gen_smtp, after calling the trace function with each
  # of `traces`, as gen_smtp does; an answer `:raise` raises.
  defmodule Answering do
    @moduledoc false
    use Swoosh.Adapter

    def deliver(_email, config) do
      {answer, traces} = Process.get(:answer)
      for format <- traces, do: config[:trace_fun].(format, ["the relay's reply"])
      if answer == :raise, do: raise("no connection to smtp.example.com"), else: answer
    end
  end

  @attrs %{
    "smtp_relay" => "smtp.example.com",
    "smtp_port" => "587",
    "smtp_tls" => "always",
    "smtp_username" => "qory",
    "smtp_password" => @password,
    "mail_from" => "qory@example.com"
  }

  # Puts the application's setting `key` of `app` for the test, and back after it.
  defp put_env(app \\ :apiary, key, value) do
    before = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case before do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  # Production without SMTP_RELAY (config/runtime.exs): the environment sets no mail.
  defp no_env_mail, do: put_env(Apiary.Mailer, adapter: nil)

  # Runs `fun` with the tests' mail, for a fixture that sends an invitation.
  defp with_env_mail(fun) do
    Application.put_env(:apiary, Apiary.Mailer, adapter: Swoosh.Adapters.Test)

    try do
      fun.()
    after
      Application.put_env(:apiary, Apiary.Mailer, adapter: nil)
    end
  end

  defp url(token), do: "https://qory.example.com/instance/mail/confirm/#{token}"

  # The token of the test link in the email the admin was sent.
  defp sent_token do
    assert_received {:sent, email, _config}
    [_, token] = Regex.run(~r{/instance/mail/confirm/([A-Za-z0-9_-]+)}, email.text_body)
    token
  end

  # Saves, a minute or more after the last test send.
  defp save!(scope, attrs \\ @attrs) do
    unthrottle!()

    assert {:ok, %Settings{} = settings, %{result: :sent}} =
             Mail.save_settings(scope, attrs, &url/1)

    settings
  end

  # The last test send, a minute and a second ago: the next one is allowed.
  defp unthrottle!,
    do:
      Repo.update_all(from(s in Settings, where: not is_nil(s.mail_test_sent_at)),
        set: [mail_test_sent_at: DateTime.add(DateTime.utc_now(), -61, :second)]
      )

  defp row, do: Repo.get!(Settings, true)

  # Nothing of mail is saved: no row of the instance's settings, or one that holds none of
  # the mail's columns, as the instance's set-up leaves it (`Apiary.Setup`).
  defp no_mail_saved? do
    case Mail.settings() do
      nil ->
        true

      settings ->
        settings
        |> Map.take(Apiary.Mail.Settings.__schema__(:fields) -- [:id, :updated_at])
        |> Map.values()
        |> Enum.all?(&is_nil/1)
    end
  end

  # The Install guide as the documentation tree with `features` has it.
  defp install_guide(features) do
    path = Path.expand("../../guides/install.md", __DIR__)
    path |> File.read!() |> Mix.Tasks.Docs.All.split!(path) |> Mix.Tasks.Docs.All.join(features)
  end

  defp flat(text), do: text |> String.split() |> Enum.join(" ")

  # Makes the saved password one the instance cannot read, as a row changed outside the
  # application is: its key id names a key the instance does not hold. Under another
  # APIARY_ENCRYPTION_SECRET the instance does not start at all (`Apiary.KeyCheck`).
  defp unreadable!,
    do: Repo.update_all(Settings, set: [mail_key_id: "0000000000000000"])

  # `scope` as a sign-in `minutes` ago leaves it (`Apiary.Accounts.sudo_mode?/2`).
  defp signed_in(scope, minutes \\ 0),
    do: put_in(scope.user.authenticated_at, DateTime.add(DateTime.utc_now(), -minutes, :minute))

  # The trail's entries of `action` in the instance's organisation.
  defp entries(action) do
    Repo.all(
      from e in Apiary.Audit.Entry,
        where: e.action == ^action,
        where: e.organisation_id == ^Apiary.Edition.instance_organisation_id()
    )
  end

  setup do
    Apiary.EditionKit.hide_instance_organisation()
    %{scope: scope, user: user} = sign_up_fixture()
    assert Apiary.Access.instance_admin?(scope)
    put_env(Mail, smtp_adapter: Capture)
    no_env_mail()
    %{scope: signed_in(scope), user: user}
  end

  describe "save_settings/3" do
    test "keeps the password encrypted under the :mail key, bound to the settings, and nothing of it in clear",
         %{scope: scope} do
      settings = save!(scope)

      assert settings.smtp_password == nil
      refute inspect(settings) =~ @password

      row = row()
      {key_id, _key} = KeyDerivation.key(:mail)
      assert row.mail_key_id == key_id
      refute row.smtp_password_ciphertext =~ @password
      assert Password.decrypt(row) == {:ok, @password}

      assert {row.smtp_relay, row.smtp_port, row.smtp_tls, row.smtp_username, row.mail_from} ==
               {"smtp.example.com", 587, "always", "qory", "qory@example.com"}

      assert row.mail_saved_by_id == scope.user.id
      assert row.mail_verified_at == nil

      %{rows: [[stored]]} =
        Repo.query!("SELECT smtp_password_ciphertext FROM instance_settings")

      refute stored =~ @password
    end

    test "sends the test link to the admin who saved, through the settings saved",
         %{scope: scope, user: user} do
      save!(scope)

      assert_received {:sent, email, config}
      assert email.to == [{"", user.email}]
      assert email.from == {"Qory Apiary", "qory@example.com"}
      assert email.subject == "Turn on mail for Qory Apiary"
      assert email.text_body =~ "https://qory.example.com/instance/mail/confirm/"
      assert email.text_body =~ "The link works once, for 60 minutes, and only for you."

      assert config[:adapter] == Capture
      assert config[:relay] == "smtp.example.com"
      assert config[:port] == 587
      assert config[:username] == "qory"
      assert config[:password] == @password
      assert config[:auth] == :always
      assert config[:tls] == :always
      assert config[:ssl] == false

      # Hashed in the database: the token in the link is not there.
      [_, token] = Regex.run(~r{/confirm/([A-Za-z0-9_-]+)}, email.text_body)
      [user_token] = Repo.all_by(UserToken, context: "instance_mail")
      assert user_token.user_id == user.id
      assert user_token.token == :crypto.hash(:sha256, Base.url_decode64!(token, padding: false))
    end

    test "port 465 is TLS from the start, and no username is no log-in", %{scope: scope} do
      save!(scope, %{@attrs | "smtp_port" => "465", "smtp_username" => "", "smtp_password" => ""})

      assert_received {:sent, _email, config}
      assert {config[:ssl], config[:tls], config[:auth]} == {true, :never, :never}
      # Absent, not nil: the SMTP adapter refuses a nil username or password at each send.
      refute Keyword.has_key?(config, :username) or Keyword.has_key?(config, :password)
      assert row().smtp_password_ciphertext == nil and row().mail_key_id == nil
    end

    test "empty fields take the defaults the variables have", %{scope: scope} do
      save!(scope, %{
        "smtp_relay" => " smtp.example.com ",
        "smtp_port" => "",
        "smtp_tls" => "",
        "smtp_username" => "",
        "smtp_password" => "",
        "mail_from" => ""
      })

      row = row()

      assert {row.smtp_relay, row.smtp_port, row.smtp_tls, row.smtp_username, row.mail_from} ==
               {"smtp.example.com", 587, "always", nil, nil}

      # The sender is the server's default.
      assert_received {:sent, email, _config}
      assert email.from == {"Qory Apiary", Apiary.Mailer.default_address()}
    end

    test "keeps the saved password while nothing it is bound to changes, and asks for it again when something does",
         %{scope: scope} do
      save!(scope)
      first = row().smtp_password_ciphertext

      # Left empty, with only the sender changed: the same ciphertext, sent with it.
      save!(scope, %{@attrs | "smtp_password" => "", "mail_from" => "mail@example.com"})
      assert row().smtp_password_ciphertext == first
      assert_received {:sent, _email, _config}
      assert_received {:sent, _email, config}
      assert config[:password] == @password

      # Each of what it is bound to, changed with the password left empty: asked again,
      # and nothing saved.
      for {field, value} <- [
            {"smtp_relay", "smtp.example.net"},
            {"smtp_port", "2525"},
            {"smtp_username", "someone-else"}
          ] do
        attrs = %{@attrs | "smtp_password" => ""} |> Map.put(field, value)
        assert {:error, changeset} = Mail.save_settings(scope, attrs, &url/1)

        assert errors_on(changeset) == %{
                 smtp_password: ["enter it again: the relay, port, TLS or username changed"]
               }

        assert row().smtp_password_ciphertext == first
      end

      # Given again with the change: saved, under the new settings.
      save!(scope, %{@attrs | "smtp_relay" => "smtp.example.net"})
      assert Password.decrypt(row()) == {:ok, @password}
      refute row().smtp_password_ciphertext == first

      # TLS changed, on port 465, where it may be anything with a username.
      save!(scope, %{@attrs | "smtp_port" => "465"})
      on_465 = row().smtp_password_ciphertext
      attrs = %{@attrs | "smtp_port" => "465", "smtp_password" => "", "smtp_tls" => "never"}
      assert {:error, changeset} = Mail.save_settings(scope, attrs, &url/1)

      assert errors_on(changeset) == %{
               smtp_password: ["enter it again: the relay, port, TLS or username changed"]
             }

      assert row().smtp_password_ciphertext == on_465
    end

    test "TLS is Always with a username, but on port 465, so the password is never sent unencrypted",
         %{scope: scope} do
      for tls <- ["never", "if_available"] do
        assert {:error, changeset} =
                 Mail.save_settings(scope, %{@attrs | "smtp_tls" => tls}, &url/1)

        assert errors_on(changeset) == %{smtp_tls: ["must be Always with a username"]}
        refute inspect(changeset, limit: :infinity, printable_limit: :infinity) =~ @password
      end

      assert no_mail_saved?()

      # Without a username, there is no password to protect; on port 465, TLS is from the
      # start whatever this says.
      no_login = %{@attrs | "smtp_username" => "", "smtp_password" => ""}

      for attrs <- [
            %{no_login | "smtp_tls" => "never"},
            %{no_login | "smtp_tls" => "if_available"},
            %{@attrs | "smtp_tls" => "never", "smtp_port" => "465"}
          ] do
        save!(scope, attrs)
      end
    end

    test "the relay, the username and the sender are counted in bytes, which the password's encryption binds",
         %{scope: scope} do
      # One character, a letter with 40,000 combining accents: 80,001 bytes.
      long = "a" <> String.duplicate("\u0301", 40_000)
      assert String.length(long) == 1

      for {field, error} <- [
            {"smtp_username", "should be at most 320 byte(s)"},
            {"mail_from", "should be at most 160 byte(s)"}
          ] do
        value = if field == "mail_from", do: long <> "@example.com", else: long

        assert {:error, changeset} =
                 Mail.save_settings(scope, Map.put(@attrs, field, value), &url/1)

        assert errors_on(changeset) == %{String.to_existing_atom(field) => [error]}
      end

      assert {:error, changeset} =
               Mail.save_settings(scope, %{@attrs | "smtp_relay" => long}, &url/1)

      assert "should be at most 253 byte(s)" in errors_on(changeset).smtp_relay
      assert no_mail_saved?()
    end

    test "TLS checks the relay's certificate and name, and the relay is the host connected to",
         %{scope: scope} do
      no_login = %{@attrs | "smtp_username" => "", "smtp_password" => ""}

      for {attrs, ssl, tls, key} <- [
            {@attrs, false, :always, :tls_options},
            {%{no_login | "smtp_tls" => "if_available"}, false, :if_available, :tls_options},
            {%{no_login | "smtp_tls" => "never"}, false, :never, :tls_options},
            {%{@attrs | "smtp_port" => "465"}, true, :never, :sockopts}
          ] do
        save!(scope, attrs)
        assert_received {:sent, _email, config}
        assert {config[:ssl], config[:tls]} == {ssl, tls}
        assert config[:no_mx_lookups] == true
        # sockopts are also the plain connection's: only for TLS from the start.
        refute Keyword.has_key?(config, if(key == :sockopts, do: :tls_options, else: :sockopts))

        options = Keyword.fetch!(config, key)
        assert options[:verify] == :verify_peer
        assert options[:cacerts] == :public_key.cacerts_get()
        assert options[:cacerts] != []
        assert options[:depth] == 10
        assert options[:versions] == [:"tlsv1.2", :"tlsv1.3"]
        assert options[:server_name_indication] == ~c"smtp.example.com"
        assert [match_fun: match_fun] = options[:customize_hostname_check]
        assert is_function(match_fun, 2)
        refute Keyword.has_key?(options, :verify_fun)
      end
    end

    test "a relay given as an IP address sends no server name, and its certificate must name the address",
         %{scope: scope} do
      for {relay, ip} <- [{"192.0.2.10", {192, 0, 2, 10}}, {"2001:db8::10", nil}] do
        if ip do
          save!(scope, %{@attrs | "smtp_relay" => relay})
          assert_received {:sent, _email, config}
          options = config[:tls_options]
          assert options[:verify] == :verify_peer
          assert options[:server_name_indication] == :disable
          assert options[:verify_fun] == {&Apiary.Mail.TLS.verify_ip/3, ip}
          refute Keyword.has_key?(options, :customize_hostname_check)
        else
          # The form takes no IPv6 address; the environment's relay may be one.
          options = Apiary.Mail.TLS.ssl_options(relay)
          assert options[:server_name_indication] == :disable
          assert {_fun, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x10}} = options[:verify_fun]
        end
      end
    end

    test "is refused to an instance admin whose sign-in is not recent, who signs in again first",
         %{scope: scope} do
      for stale <- [signed_in(scope, 21), put_in(scope.user.authenticated_at, nil)] do
        assert Mail.save_settings(stale, @attrs, &url/1) == {:error, :sudo}
      end

      assert no_mail_saved?()
      refute_received {:sent, _email, _config}
      assert entries("instance.mail_save") == []

      save!(signed_in(scope, 19))
    end

    test "is an instance.mail_save entry in the instance's trail, by the admin, without the password or any address",
         %{scope: scope} do
      save!(scope)
      assert [entry] = entries("instance.mail_save")
      assert {entry.actor_kind, entry.actor_id} == {:person, scope.user.id}
      assert {entry.subject_kind, entry.subject_id} == {"organisation", entry.organisation_id}

      # Written before the test send, the entry has no result.
      assert entry.details == %{
               "relay" => "smtp.example.com",
               "port" => 587,
               "tls" => "always",
               "username" => true,
               "sender" => true
             }

      kept = Jason.encode!([entry.before, entry.after, entry.details])
      refute kept =~ @password
      refute kept =~ "qory@example.com"
      refute kept =~ "\"qory\""

      assert Describer.sentence(:"instance.mail_save", entry, %{}) ==
               "Saved the mail settings and started a test send"

      # A refused save leaves none, and so does one within the minute, which saves nothing.
      assert {:error, _changeset} =
               Mail.save_settings(scope, %{@attrs | "smtp_relay" => ""}, &url/1)

      assert {:error, {:throttled, _at}} = Mail.save_settings(scope, @attrs, &url/1)
      assert [_one] = entries("instance.mail_save")
    end

    test "a save whose test link the relay refused keeps its entry, which is never changed",
         %{scope: scope} do
      put_env(Mail, smtp_adapter: Refusing)

      {{:ok, _settings, %{result: :rejected}}, _log} =
        with_log(fn -> Mail.save_settings(scope, @attrs, &url/1) end)

      assert [entry] = entries("instance.mail_save")
      refute Map.has_key?(entry.details, "result") or Map.has_key?(entry.details, "reply_code")
      refute Jason.encode!(entry.details) =~ "550"

      assert Describer.sentence(:"instance.mail_save", entry, %{}) ==
               "Saved the mail settings and started a test send"

      # The result is on the row alone; a later test send leaves the entry as it was.
      assert {row().mail_test_result, row().mail_test_reply_code} == {:rejected, "550"}
      put_env(Mail, smtp_adapter: Capture)
      unthrottle!()
      assert {:ok, %{result: :sent}} = Mail.resend_test_link(scope, &url/1)
      assert Repo.get!(Apiary.Audit.Entry, entry.id) == entry
    end

    test "a saved password that cannot be read is asked for again, saying so", %{scope: scope} do
      save!(scope)
      unreadable!()

      assert {:error, changeset} =
               Mail.save_settings(scope, %{@attrs | "smtp_password" => ""}, &url/1)

      assert errors_on(changeset) == %{
               smtp_password: ["enter it again: the saved one cannot be read"]
             }

      # Given again, it is saved.
      save!(scope)
      assert Password.decrypt(row()) == {:ok, @password}
    end

    test "a username needs a password, and a password a username", %{scope: scope} do
      assert {:error, changeset} =
               Mail.save_settings(scope, %{@attrs | "smtp_password" => ""}, &url/1)

      assert errors_on(changeset) == %{smtp_password: ["can't be blank"]}

      assert {:error, changeset} =
               Mail.save_settings(scope, %{@attrs | "smtp_username" => " "}, &url/1)

      assert errors_on(changeset) == %{smtp_username: ["can't be blank with a password"]}
      assert no_mail_saved?()
    end

    test "a refused save keeps nothing, and its changeset holds no password", %{scope: scope} do
      for {field, value, error} <- [
            {"smtp_relay", "https://smtp.example.com",
             "must be a host name, such as smtp.example.com"},
            {"smtp_relay", "", "can't be blank"},
            {"smtp_port", "70000", "must be less than or equal to 65535"},
            {"smtp_tls", "sometimes", "is invalid"},
            {"mail_from", "qory at example.com", "must have the @ sign and no spaces"},
            {"mail_from", "Qory <qory@example.com>", "must have the @ sign and no spaces"},
            {"mail_from", "qory\"@example.com", "must have the @ sign and no spaces"},
            {"mail_from", "qory#{<<0xA0::utf8>>}@example.com",
             "must have the @ sign and no spaces"},
            {"mail_from", "qo\0ry@example.com", "must not contain control characters"},
            {"mail_from", "qo\ary@example.com", "must not contain control characters"},
            {"mail_from", "qo#{<<0x202E::utf8>>}ry@example.com",
             "must not contain control characters"},
            {"mail_from", "qo#{<<0x200D::utf8>>}ry@example.com",
             "must not contain control characters"},
            {"mail_from", <<0xFF>> <> "qory@example.com", "must be UTF-8 text"}
          ] do
        assert {:error, changeset} =
                 Mail.save_settings(scope, Map.put(@attrs, field, value), &url/1)

        assert Map.values(errors_on(changeset)) == [[error]], inspect({field, value})
        refute inspect(changeset, limit: :infinity, printable_limit: :infinity) =~ @password
        refute Map.has_key?(changeset.changes, :smtp_password)
        assert changeset.params["smtp_password"] == ""
      end

      assert no_mail_saved?()
      refute_received {:sent, _email, _config}
    end

    test "a refused save's changeset and the settings shown hold nothing of the saved password",
         %{scope: scope} do
      save!(scope)
      ciphertext = row().smtp_password_ciphertext
      assert is_binary(ciphertext)

      # Refused by the changeset, with a password given; and by the password kept, none given.
      for attrs <- [
            %{@attrs | "smtp_relay" => "smtp example com"},
            %{@attrs | "smtp_password" => "", "smtp_port" => "2525"}
          ] do
        assert {:error, changeset} = Mail.save_settings(scope, attrs, &url/1)
        assert changeset.data.smtp_password_ciphertext == nil
        refute Map.has_key?(changeset.changes, :smtp_password_ciphertext)
        assert :binary.match(:erlang.term_to_binary(changeset), ciphertext) == :nomatch
      end

      assert %{settings: settings, state: :pending, password_saved: true} = Mail.shown()
      assert settings.smtp_password_ciphertext == nil
      assert {settings.smtp_relay, settings.smtp_username} == {"smtp.example.com", "qory"}
      assert :binary.match(:erlang.term_to_binary(Mail.shown()), ciphertext) == :nomatch

      # The row keeps it, and the sender reads it from there.
      assert row().smtp_password_ciphertext == ciphertext
      assert Password.decrypt(Mail.settings()) == {:ok, @password}

      unreadable!()
      assert %{state: :unreadable, password_saved: false} = Mail.shown()
    end

    test "saved, and the test link not sent: the settings are kept, and say so", %{scope: scope} do
      put_env(Mail, smtp_adapter: Refusing)

      {answer, _log} = with_log(fn -> Mail.save_settings(scope, @attrs, &url/1) end)
      assert {:ok, settings, %{result: :rejected, reply_code: "550"}} = answer

      assert {settings.mail_test_result, settings.mail_test_reply_code} == {:rejected, "550"}
      assert Mail.state(row()) == :pending
      # No link went out, so none waits.
      refute Mail.test_link_waiting?(row())
      assert Repo.all_by(UserToken, context: "instance_mail") == []
    end

    test "a test link waits while it can still be followed", %{scope: scope, user: user} do
      save!(scope)
      assert Mail.test_link_waiting?(row())

      # Its 60 minutes past.
      Repo.update_all(from(t in UserToken, where: t.context == "instance_mail"),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -61, :minute)]
      )

      refute Mail.test_link_waiting?(row())

      # The admin's address changed since.
      save!(scope)

      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [email: "dana@example.com"]
      )

      refute Mail.test_link_waiting?(row())
      refute Mail.test_link_waiting?(nil)
    end

    test "a save ends every test link sent before, and turns mail off until the new one is followed",
         %{scope: scope} do
      save!(scope)
      first = sent_token()
      assert {:ok, _settings} = Mail.turn_on(scope, first)
      assert Mail.source() == :settings

      save!(scope, %{@attrs | "smtp_password" => ""})
      assert Mail.state(row()) == :pending
      assert Mail.source() == :none
      second = sent_token()

      save!(scope, %{@attrs | "smtp_password" => ""})
      assert Mail.turn_on(scope, second) == :error
      assert Mail.turn_on(scope, sent_token()) |> elem(0) == :ok
      assert Repo.all_by(UserToken, context: "instance_mail") == []
    end

    test "is refused to anyone but an instance admin", %{scope: scope} do
      {member, admin, stranger} =
        with_env_mail(fn ->
          {member_fixture(scope).scope, member_fixture(scope, :admin).scope,
           sign_up_fixture().scope}
        end)

      for other <- [member, admin, stranger, nil] do
        assert Mail.save_settings(other, @attrs, &url/1) == {:error, :forbidden}
      end

      assert no_mail_saved?()
    end

    test "is refused while the environment sets mail, which wins whole", %{scope: scope} do
      put_env(Apiary.Mailer, adapter: Swoosh.Adapters.Test)

      assert Mail.save_settings(scope, @attrs, &url/1) == {:error, :env}
      assert no_mail_saved?()
    end
  end

  describe "a test send's result" do
    @host ~c"smtp.example.com"
    @mail_from ~c"Mail FROM rejected: ~p~n"

    # Each answer of `Swoosh.Adapters.SMTP` for gen_smtp 1.3, with the formats gen_smtp
    # traced, and the result, the reply code and the reason it is.
    @answers [
      {{:ok, "250 queued"}, [], {:sent, nil, nil}},
      {{:error, {:retries_exceeded, {:network_failure, @host, {:error, :econnrefused}}}}, [],
       {:connect, nil, :econnrefused}},
      {{:error, {:retries_exceeded, {:network_failure, @host, {:error, :nxdomain}}}}, [],
       {:connect, nil, :nxdomain}},
      {{:error,
        {:retries_exceeded,
         {:network_failure, @host, {:error, {:tls_alert, {:unknown_ca, ~c"unknown ca"}}}}}}, [],
       {:tls, nil, nil}},
      {{:error, {:retries_exceeded, {:temporary_failure, @host, :tls_failed}}}, [],
       {:tls, nil, nil}},
      {{:error, {:retries_exceeded, {:missing_requirement, @host, :tls}}}, [], {:tls, nil, nil}},
      {{:error, {:no_more_hosts, {:permanent_failure, @host, :auth_failed}}}, [],
       {:login, nil, nil}},
      {{:error, {:retries_exceeded, {:missing_requirement, @host, :auth}}}, [],
       {:login, nil, nil}},
      {{:error,
        {:send,
         {:permanent_failure, @host,
          "550 5.7.1 Sender qory@example.com refused for 192.0.2.7 by smtp.example.com\r\n"}}},
       [@mail_from], {:sender, "550 5.7.1", nil}},
      {{:error,
        {:send,
         {:permanent_failure, @host,
          "550 5.7.1 Recipient refused for 192.0.2.7 by smtp.example.com\r\n"}}}, [],
       {:rejected, "550 5.7.1", nil}},
      {{:error, {:no_more_hosts, {:permanent_failure, @host, "554 No service\r\n"}}}, [],
       {:rejected, "554", nil}},
      {{:error,
        {:send, {:temporary_failure, @host, "451-4.3.0 Try again later\r\n451 4.3.0 Later\r\n"}}},
       [], {:temporary, "451 4.3.0", nil}},
      {{:error, {:retries_exceeded, {:temporary_failure, @host, "421 Too busy\r\n"}}}, [],
       {:temporary, "421", nil}},
      {{:error, {:retries_exceeded, {:unexpected_response, @host, ["SMTP? no"]}}}, [],
       {:other, nil, nil}},
      {{:error, {:no_more_hosts, {:permanent_failure, @host, :ssl_not_started}}}, [],
       {:other, nil, nil}},
      {{:error, {:send, {:permanent_failure, @host, "refused\r\n"}}}, [@mail_from],
       {:other, nil, nil}},
      {{:error, :no_credentials}, [], {:other, nil, nil}},
      {:raise, [], {:other, nil, nil}}
    ]

    setup do
      put_env(Mail, smtp_adapter: Answering)
      :ok
    end

    test "is classed from the adapter's answer, and keeps the class and the reply code alone",
         %{scope: scope} do
      for {answer, traces, {result, code, reason}} <- @answers do
        Process.put(:answer, {answer, traces})
        unthrottle!()

        {{:ok, settings, test_send}, log} =
          with_log(fn -> Mail.save_settings(scope, @attrs, &url/1) end)

        assert {test_send.result, test_send.reply_code, test_send.reason} ==
                 {result, code, reason},
               inspect(answer)

        assert {settings.mail_test_result, settings.mail_test_reply_code} == {result, code}
        row = row()
        assert {row.mail_test_result, row.mail_test_reply_code} == {result, code}
        assert DateTime.compare(row.mail_test_sent_at, test_send.sent_at) == :eq

        # Never the relay's text, its host, this server's address or the sender's.
        %{rows: [kept]} =
          Repo.query!(
            "SELECT mail_test_result, mail_test_reply_code FROM instance_settings WHERE id"
          )

        kept = Enum.join(Enum.reject(kept, &is_nil/1), " ")

        for word <- ["refused", "192.0.2.7", "smtp.example.com", "qory@example.com", "later"],
            do: refute(kept =~ word)

        if result == :sent do
          assert log == ""
          assert Mail.test_link_waiting?(row)
        else
          # One line, with the class and the reply code alone; the link is ended.
          assert log =~ "The test link of the mail settings was not sent: #{result}"
          if code, do: assert(log =~ ", reply code #{code}")

          for word <- ["192.0.2.7", "smtp.example.com", "qory@example.com", "econnrefused"],
              do: refute(log =~ word)

          refute Mail.test_link_waiting?(row)
          assert Repo.all_by(UserToken, context: "instance_mail") == []
        end
      end
    end

    test "test_result/2 tells the sender apart only by gen_smtp's trace of MAIL FROM" do
      refused =
        {:error, {:send, {:permanent_failure, @host, "553 5.1.8 Sender address refused\r\n"}}}

      assert Mail.test_result(refused, true) == {:sender, "553 5.1.8", nil}
      assert Mail.test_result(refused, false) == {:rejected, "553 5.1.8", nil}

      # Refused before the email, as the session opened: never the sender.
      assert Mail.test_result(
               {:error, {:no_more_hosts, {:permanent_failure, @host, "554 5.7.1 No\r\n"}}},
               true
             ) == {:rejected, "554 5.7.1", nil}
    end

    test "a save within the minute after the last test send saves and sends nothing, and says until when",
         %{scope: scope} do
      Process.put(:answer, {{:ok, "250 queued"}, []})
      save!(scope)
      sent_at = row().mail_test_sent_at
      before = row()

      assert {:error, {:throttled, allowed_at}} =
               Mail.save_settings(scope, %{@attrs | "mail_from" => "mail@example.com"}, &url/1)

      assert allowed_at == DateTime.add(sent_at, 60, :second)
      assert Mail.test_send_seconds() == 60
      assert row() == before
      assert entries("instance.mail_save") |> length() == 1

      # A minute on, it saves.
      unthrottle!()

      assert {:ok, _settings, %{result: :sent}} =
               Mail.save_settings(scope, %{@attrs | "mail_from" => "mail@example.com"}, &url/1)

      assert row().mail_from == "mail@example.com"
    end

    # The adapter the release uses, against a relay on this machine that answers as told:
    # gen_smtp traces a refusal of MAIL FROM, and of no other command.
    test "through Swoosh's SMTP adapter, a relay that refuses the sender, a recipient, or for now",
         %{scope: scope} do
      put_env(Mail, smtp_adapter: Swoosh.Adapters.SMTP)

      attrs = %{
        @attrs
        | "smtp_relay" => "127.0.0.1",
          "smtp_tls" => "never",
          "smtp_username" => "",
          "smtp_password" => "",
          "mail_from" => ""
      }

      for {replies, result, code} <- [
            {%{"MAIL" => "550 5.7.1 Sender not verified for 192.0.2.7"}, :sender, "550 5.7.1"},
            {%{"RCPT" => "550 5.1.1 No such recipient"}, :rejected, "550 5.1.1"},
            {%{"DATA" => "554 5.6.0 Message refused"}, :rejected, "554 5.6.0"},
            {%{"MAIL" => "451 4.7.1 Try again later"}, :temporary, "451 4.7.1"},
            {%{}, :sent, nil}
          ] do
        {port, relay} = relay(replies)
        unthrottle!()

        {{:ok, _settings, test_send}, _log} =
          with_log(fn ->
            Mail.save_settings(scope, %{attrs | "smtp_port" => to_string(port)}, &url/1)
          end)

        assert {test_send.result, test_send.reply_code} == {result, code}, inspect(replies)
        commands = Task.await(relay)
        assert "MAIL FROM:<#{Apiary.Mailer.default_address()}>" in commands
      end

      # Nothing listens: the connection is refused.
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)
      unthrottle!()

      {{:ok, _settings, test_send}, _log} =
        with_log(fn ->
          Mail.save_settings(scope, %{attrs | "smtp_port" => to_string(port)}, &url/1)
        end)

      assert {test_send.result, test_send.reason} == {:connect, :econnrefused}
    end
  end

  describe "resend_test_link/2" do
    setup %{scope: scope} do
      save!(scope)
      first = sent_token()
      unthrottle!()
      %{first: first}
    end

    test "for the admin who saved: ends the link sent before, sends a new one, and changes no setting",
         %{scope: scope, first: first} do
      before = row()

      assert {:ok, %{result: :sent, reply_code: nil, sent_at: sent_at}} =
               Mail.resend_test_link(scope, &url/1)

      second = sent_token()
      refute second == first

      after_ = row()
      assert DateTime.compare(after_.mail_test_sent_at, sent_at) == :eq
      assert after_.mail_test_result == :sent

      assert Map.drop(after_, [:mail_test_sent_at]) ==
               Map.drop(before, [:mail_test_sent_at])

      assert Mail.turn_on(scope, first) == :error
      assert {:ok, _settings} = Mail.turn_on(scope, second)
    end

    test "is an instance.mail_resend entry, by the admin, with the result and the reply code alone",
         %{scope: scope} do
      assert {:ok, %{result: :sent}} = Mail.resend_test_link(scope, &url/1)
      token = sent_token()

      assert [entry] = entries("instance.mail_resend")
      assert {entry.actor_kind, entry.actor_id} == {:person, scope.user.id}
      assert {entry.subject_kind, entry.subject_id} == {"organisation", entry.organisation_id}
      assert entry.details == %{"result" => "sent", "reply_code" => nil}

      assert Describer.sentence(:"instance.mail_resend", entry, %{}) ==
               "Sent the test link again"

      kept = Jason.encode!([entry.before, entry.after, entry.details])

      for word <- [@password, token, "qory@example.com", "smtp.example.com"],
          do: refute(kept =~ word)

      # Refused by the relay: the result, the reply code, and the link ended.
      put_env(Mail, smtp_adapter: Refusing)
      unthrottle!()

      {{:ok, %{result: :rejected, reply_code: "550"}}, _log} =
        with_log(fn -> Mail.resend_test_link(scope, &url/1) end)

      assert {row().mail_test_result, row().mail_test_reply_code} == {:rejected, "550"}
      refute Mail.test_link_waiting?(row())

      assert [_one, %{details: %{"result" => "rejected", "reply_code" => "550"}} = refused] =
               Enum.sort_by(entries("instance.mail_resend"), & &1.inserted_at, DateTime)

      assert Describer.sentence(:"instance.mail_resend", refused, %{}) ==
               "Tried to send the test link again; the relay did not accept it"
    end

    test "within the minute after the last test send, sends nothing, and says until when",
         %{scope: scope} do
      assert {:ok, %{sent_at: sent_at}} = Mail.resend_test_link(scope, &url/1)
      _token = sent_token()
      allowed_at = DateTime.add(sent_at, 60, :second)

      assert Mail.resend_test_link(scope, &url/1) == {:error, {:throttled, allowed_at}}

      # A save is held to the same minute.
      assert Mail.save_settings(scope, @attrs, &url/1) == {:error, {:throttled, allowed_at}}
      refute_received {:sent, _email, _config}
      assert [_one] = entries("instance.mail_resend")
    end

    test "is refused to another instance admin, a sign-in not recent, mail from the environment, and mail already on",
         %{scope: scope, first: first} do
      %{scope: other} = with_env_mail(fn -> member_fixture(scope, :owner) end)
      other = signed_in(other)
      assert Apiary.Access.instance_admin?(other)
      before = row()

      assert Mail.resend_test_link(other, &url/1) == {:error, :not_saver}
      assert Mail.resend_test_link(signed_in(scope, 21), &url/1) == {:error, :sudo}
      assert Mail.resend_test_link(nil, &url/1) == {:error, :forbidden}

      member = with_env_mail(fn -> member_fixture(scope).scope end)
      assert Mail.resend_test_link(signed_in(member), &url/1) == {:error, :forbidden}

      put_env(Apiary.Mailer, adapter: Swoosh.Adapters.Test)
      assert Mail.resend_test_link(scope, &url/1) == {:error, :env}
      no_env_mail()

      assert row() == before
      refute_received {:sent, _email, _config}
      assert entries("instance.mail_resend") == []

      # Mail on: nothing waits for a link.
      assert {:ok, _settings} = Mail.turn_on(scope, first)
      assert Mail.resend_test_link(scope, &url/1) == {:error, :not_pending}
      refute_received {:sent, _email, _config}
    end

    test "is refused where nothing is saved", %{scope: scope} do
      Repo.update_all(Settings, set: [smtp_relay: nil])
      assert Mail.resend_test_link(scope, &url/1) == {:error, :not_pending}
    end
  end

  describe "sent_or_on?/1" do
    test "is true once mail is on, or the relay accepted the last test link", %{scope: scope} do
      refute Mail.sent_or_on?(nil)
      save!(scope)
      _first = sent_token()
      assert Mail.sent_or_on?(row())

      put_env(Mail, smtp_adapter: Refusing)
      unthrottle!()

      {{:ok, _settings, %{result: :rejected}}, _log} =
        with_log(fn -> Mail.save_settings(scope, @attrs, &url/1) end)

      refute Mail.sent_or_on?(row())

      put_env(Mail, smtp_adapter: Capture)
      save!(scope)
      assert {:ok, _settings} = Mail.turn_on(scope, sent_token())
      assert Mail.sent_or_on?(row())
    end
  end

  # A relay on this machine, for one connection: it answers each command with its reply in
  # `replies`, by the command's name, or with one that accepts it. Returns the port, and a
  # task whose result is the commands it read.
  defp relay(replies) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        :ok = :gen_tcp.close(listen)
        :ok = :gen_tcp.send(socket, "220 relay.example.com\r\n")
        converse(socket, replies, [])
      end)

    {port, task}
  end

  defp converse(socket, replies, commands) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, line} ->
        line = String.trim_trailing(line, "\r\n")
        [name | _rest] = String.split(line, [" ", ":"])
        name = String.upcase(name)

        reply =
          case name do
            "QUIT" -> "221 Bye"
            "DATA" -> Map.get(replies, "DATA", "250 Queued") |> data(socket)
            "EHLO" -> "250 relay.example.com"
            _command -> Map.get(replies, name, "250 OK")
          end

        :gen_tcp.send(socket, reply <> "\r\n")

        if name == "QUIT" do
          :gen_tcp.close(socket)
          Enum.reverse([line | commands])
        else
          converse(socket, replies, [line | commands])
        end

      {:error, _closed} ->
        Enum.reverse(commands)
    end
  end

  # DATA: go ahead, read the email to its last line, and the reply to it.
  defp data(reply, socket) do
    :ok = :gen_tcp.send(socket, "354 Go ahead\r\n")
    read_email(socket)
    reply
  end

  defp read_email(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _line} -> read_email(socket)
    end
  end

  describe "turn_on/2, the test link" do
    setup %{scope: scope} do
      save!(scope)
      %{token: sent_token()}
    end

    test "for the admin who saved, signed in: turns mail on and confirms their address, and nothing else",
         %{scope: scope, user: user, token: token} do
      # Unconfirmed, with a password, and one session.
      hashed = Bcrypt.hash_pwd_salt("a password of theirs")

      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [confirmed_at: nil, hashed_password: hashed]
      )

      sessions = Repo.aggregate(from(t in UserToken, where: t.context == "session"), :count)

      assert {:ok, %Settings{mail_verified_at: %DateTime{}}} = Mail.turn_on(scope, token)

      user = Repo.get!(User, user.id)
      assert %DateTime{} = user.confirmed_at
      # No password removed, and no one signed in.
      assert user.hashed_password == hashed

      assert Repo.aggregate(from(t in UserToken, where: t.context == "session"), :count) ==
               sessions

      assert Mail.state(row()) == :on
      assert Mail.source() == :settings
      assert Mail.configured?()

      # Once.
      assert Mail.turn_on(scope, token) == :error
    end

    test "never removes a password set before the address was confirmed: it is no log-in link, and a log-in link after it keeps the password",
         %{scope: scope, user: user, token: token} do
      hashed = Bcrypt.hash_pwd_salt("a password of theirs")

      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [confirmed_at: nil, hashed_password: hashed]
      )

      # The test link logs no one in: it is not a log-in link.
      assert Apiary.Accounts.login_user_by_magic_link(token) == {:error, :not_found}
      assert Repo.get!(User, user.id).hashed_password == hashed

      assert {:ok, _settings} = Mail.turn_on(scope, token)

      # Confirmed by the test link, the address's first log-in link after it keeps the
      # password: `Apiary.Accounts.login_user_by_magic_link/1` removes one only from an
      # account not yet confirmed.
      {login, user_token} = UserToken.build_email_token(Repo.get!(User, user.id), "login")
      Repo.insert!(user_token)

      assert {:ok, {%User{id: id}, []}} = Apiary.Accounts.login_user_by_magic_link(login)
      assert id == user.id
      assert Repo.get!(User, user.id).hashed_password == hashed
    end

    test "does nothing for another instance admin, and still works for the one it was sent to",
         %{scope: scope, token: token} do
      %{scope: other} = with_env_mail(fn -> member_fixture(scope, :owner) end)
      other = signed_in(other)
      assert Apiary.Access.instance_admin?(other)

      assert Mail.turn_on(other, token) == :error
      assert Mail.state(row()) == :pending

      assert {:ok, _settings} = Mail.turn_on(scope, token)
    end

    test "does nothing for anyone else, or no one", %{scope: scope, token: token} do
      {member, stranger} =
        with_env_mail(fn -> {member_fixture(scope).scope, sign_up_fixture().scope} end)

      for other <- [member, stranger, nil] do
        assert Mail.turn_on(other, token) == :error
      end

      assert Mail.state(row()) == :pending
      assert [_token] = Repo.all_by(UserToken, context: "instance_mail")
    end

    test "asks the admin who saved for a recent sign-in, and works once they have signed in again",
         %{scope: scope, token: token} do
      assert Mail.turn_on(signed_in(scope, 21), token) == {:error, :sudo}
      assert Mail.state(row()) == :pending
      assert entries("instance.mail_on") == []

      assert {:ok, _settings} = Mail.turn_on(signed_in(scope, 1), token)
    end

    test "is an instance.mail_on entry in the instance's trail, by the admin",
         %{scope: scope, token: token} do
      assert {:ok, _settings} = Mail.turn_on(scope, token)
      assert [entry] = entries("instance.mail_on")
      assert {entry.actor_kind, entry.actor_id} == {:person, scope.user.id}
      assert {entry.subject_kind, entry.subject_id} == {"organisation", entry.organisation_id}

      assert entry.details == %{
               "relay" => "smtp.example.com",
               "port" => 587,
               "password_links_ended" => 0
             }

      # Once: the link used, nothing more.
      assert Mail.turn_on(scope, token) == :error
      assert [_one] = entries("instance.mail_on")
    end

    test "ends every password link an admin made without mail, and no other token",
         %{scope: scope, token: token} do
      %{admin: admin, release: release, login: login, session: session, other: other} =
        password_links(scope)

      assert {:ok, _settings} = Mail.turn_on(scope, token)

      refute Apiary.Accounts.get_user_by_password_link(admin)
      assert [entry] = entries("instance.mail_on")
      assert entry.details["password_links_ended"] == 1

      # A release command's link is made mail or not, on purpose, and kept; a log-in link
      # and a session are not password links.
      assert %User{id: id} = Apiary.Accounts.get_user_by_password_link(release)
      assert id == other.id
      assert {%User{}, _inserted_at} = Apiary.Accounts.get_user_by_session_token(session)
      assert Repo.get_by(UserToken, token: login.token, context: "login")
    end

    test "works for 60 minutes", %{scope: scope, token: token} do
      Repo.update_all(from(t in UserToken, where: t.context == "instance_mail"),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -61, :minute)]
      )

      assert Mail.test_link_minutes() == 60
      assert Mail.turn_on(scope, token) == :error
      assert Mail.state(row()) == :pending
    end

    test "a token that is not the link's, or not one at all, does nothing", %{scope: scope} do
      for token <- ["", "not base64!", Base.url_encode64(:crypto.strong_rand_bytes(32))] do
        assert Mail.turn_on(scope, token) == :error
      end

      assert Mail.state(row()) == :pending
    end

    test "ends with a change of the admin's address", %{scope: scope, user: user, token: token} do
      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [email: "dana@example.com"]
      )

      assert Mail.turn_on(scope, token) == :error
    end
  end

  describe "boot/0, as a node starts" do
    test "with mail set, by the environment or the settings, ends every password link an admin made, and no other token",
         %{scope: scope} do
      for source <- [:env, :settings] do
        %{admin: admin, release: release, login: login, session: session} =
          password_links(scope)

        Mail.put_test_source(source)
        assert Mail.boot() == :ok
        Mail.put_test_source(:none)

        refute Apiary.Accounts.get_user_by_password_link(admin)
        assert Apiary.Accounts.get_user_by_password_link(release)
        assert Apiary.Accounts.get_user_by_session_token(session)
        assert Repo.get_by(UserToken, token: login.token, context: "login")
      end
    end

    test "without mail, keeps them", %{scope: scope} do
      %{admin: admin} = password_links(scope)
      assert Mail.boot() == :ok
      assert Apiary.Accounts.get_user_by_password_link(admin)
    end
  end

  # While no mail is set: a password link an instance admin made for an account, with its
  # log-in link and session, and one a release command printed for another account (an
  # account has one password link at a time), each a token.
  defp password_links(scope) do
    Mail.put_test_source(:env)

    {user, other} =
      with_env_mail(fn ->
        {Apiary.AccountsFixtures.user_fixture(), Apiary.AccountsFixtures.user_fixture()}
      end)

    Mail.put_test_source(:none)
    url = &"https://qory.example.com/users/password/#{&1}"

    {:ok, admin, _expires_at} = Apiary.Accounts.build_password_link(scope, user, url)

    release_scope =
      nil
      |> Apiary.Accounts.Scope.for_instance()
      |> Apiary.Accounts.Scope.put_origin(%{worker: "Apiary.Release.password_link/1"})

    {:ok, release, _expires_at} = Apiary.Accounts.build_password_link(release_scope, other, url)
    {_login, login} = UserToken.build_email_token(user, "login")
    login = Repo.insert!(login)
    session = Apiary.Accounts.generate_user_session_token(user)
    token = &(Regex.run(~r{/users/password/(.+)$}, &1) |> List.last())

    %{
      admin: token.(admin),
      release: token.(release),
      login: login,
      session: session,
      other: other
    }
  end

  describe "where mail comes from once it is on" do
    setup %{scope: scope} do
      save!(scope)
      {:ok, _settings} = Mail.turn_on(scope, sent_token())
      :ok
    end

    test "the saved settings send every email, from their sender" do
      assert Mail.source() == :settings
      config = Mail.mailer_config()
      assert config[:adapter] == Capture

      assert {config[:relay], config[:username], config[:password]} ==
               {"smtp.example.com", "qory", @password}

      assert Mail.sender() == "qory@example.com"
      assert Apiary.Mailer.from() == {"Qory Apiary", "qory@example.com"}

      user = Apiary.AccountsFixtures.user_fixture()
      flush_sent()

      assert {:ok, _email} =
               Apiary.Accounts.UserNotifier.deliver_login_instructions(
                 user,
                 "https://qory.example.com/users/log-in/example"
               )

      assert_received {:sent, email, config}
      assert email.to == [{"", user.email}]
      assert email.from == {"Qory Apiary", "qory@example.com"}
      assert config[:relay] == "smtp.example.com"
      assert config[:password] == @password
    end

    test "the environment wins whole" do
      put_env(Apiary.Mailer, adapter: Swoosh.Adapters.Test)

      assert Mail.source() == :env
      assert Mail.mailer_config() == [adapter: Swoosh.Adapters.Test]
      assert Mail.sender() == Mail.default_sender()
    end

    test "the Backup guide says the saved password cannot be read, not that a secret turns mail off" do
      # Another APIARY_ENCRYPTION_SECRET stops the boot (`Apiary.KeyCheck`): it never
      # leaves an instance running with mail off.
      guide =
        Path.expand("../../guides/backup.md", __DIR__)
        |> File.read!()
        |> String.split()
        |> Enum.join(" ")

      refute guide =~ "without it, mail from those settings is off"
      assert guide =~ "Where that saved password cannot be read, mail from those settings is off"
    end

    test "the Install guide's Mail says the settings saved send mail, on every instance" do
      relay_row =
        ~r/\| `SMTP_RELAY` \|[^\n]*Not set, and with no other mail settings, the release sends no email/

      paragraph = "An instance admin can set mail in **Instance settings › Mail** instead"

      for features <- [[:observability], [:observability, :security]] do
        guide = install_guide(features)
        assert guide =~ relay_row
        assert flat(guide) =~ paragraph
        assert flat(guide) =~ "With `SMTP_RELAY` set, these variables win whole"
        refute guide =~ "instance_mail"
      end
    end

    test "off when the password cannot be read" do
      unreadable!()

      assert Mail.state(row()) == :unreadable
      assert Mail.source() == :none
      assert Mail.mailer_config() == nil
    end
  end

  describe "Apiary.Mail.Cache, each node's copy" do
    test "holds what the database has, reads it again on every change, and leaves when it stops",
         %{scope: scope} do
      assert Cache.cached() == :error
      start_supervised!(Cache)

      assert Cache.cached() == {:ok, {:none, Mail.settings()}}

      save!(scope)
      eventually(fn -> assert {:ok, {:pending, %Settings{}}} = Cache.cached() end)

      {:ok, _settings} = Mail.turn_on(scope, sent_token())
      eventually(fn -> assert {:ok, {:on, %Settings{}}} = Cache.cached() end)
      assert Mail.source() == :settings

      stop_supervised!(Cache)
      assert Cache.cached() == :error
    end

    test "says when the saved password cannot be read, and nothing of it", %{scope: scope} do
      save!(scope)
      unreadable!()

      log = capture_log(fn -> start_supervised!(Cache) end)

      assert Cache.unreadable_message() ==
               "The SMTP password saved in Instance settings › Mail cannot be read, so mail is off. An instance admin enters it again there."

      assert log =~ Cache.unreadable_message()
      refute log =~ @password
      assert {:ok, {:unreadable, _settings}} = Cache.cached()
      stop_supervised!(Cache)
    end
  end

  defp flush_sent do
    receive do
      {:sent, _email, _config} -> flush_sent()
    after
      0 -> :ok
    end
  end

  # Asserts `fun` within a few seconds: the cache reads the row again once the broadcast
  # reaches it.
  defp eventually(fun, tries \\ 100) do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if tries == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(20)
      eventually(fun, tries - 1)
  end
end
