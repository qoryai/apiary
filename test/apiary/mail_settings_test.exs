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

  @moduletag needs: :instance_mail

  import ExUnit.CaptureLog
  import Apiary.OrganisationsFixtures

  alias Apiary.{Features, KeyDerivation, Mail}
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

  # An adapter whose relay refuses every email.
  defmodule Refusing do
    @moduledoc false
    use Swoosh.Adapter

    def deliver(_email, _config), do: {:error, {:permanent_failure, "550 refused"}}
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

  defp save!(scope, attrs \\ @attrs) do
    assert {:ok, %Settings{} = settings, :sent} = Mail.save_settings(scope, attrs, &url/1)
    settings
  end

  defp row, do: Repo.get!(Settings, true)

  # Makes the saved password one the instance cannot read, as a row changed outside the
  # application is: its key id names a key the instance does not hold. Under another
  # APIARY_ENCRYPTION_SECRET the instance does not start at all (`Apiary.KeyCheck`).
  defp unreadable!,
    do: Repo.update_all(Settings, set: [mail_key_id: "0000000000000000"])

  setup do
    Apiary.EditionKit.hide_instance_organisation()
    %{scope: scope, user: user} = sign_up_fixture()
    assert Apiary.Access.instance_admin?(scope)
    put_env(Mail, smtp_adapter: Capture)
    no_env_mail()
    %{scope: scope, user: user}
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
      assert config[:username] == nil and config[:password] == nil
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
            {"smtp_tls", "if_available"},
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
      assert Mail.settings() == nil
    end

    test "a refused save keeps nothing, and its changeset holds no password", %{scope: scope} do
      for {field, value, error} <- [
            {"smtp_relay", "https://smtp.example.com",
             "must be a host name, such as smtp.example.com"},
            {"smtp_relay", "", "can't be blank"},
            {"smtp_port", "70000", "must be less than or equal to 65535"},
            {"smtp_tls", "sometimes", "is invalid"},
            {"mail_from", "qory at example.com", "must have the @ sign and no spaces"},
            {"mail_from", "Qory <qory@example.com>", "must have the @ sign and no spaces"}
          ] do
        assert {:error, changeset} =
                 Mail.save_settings(scope, Map.put(@attrs, field, value), &url/1)

        assert Map.values(errors_on(changeset)) == [[error]], inspect({field, value})
        refute inspect(changeset, limit: :infinity, printable_limit: :infinity) =~ @password
        refute Map.has_key?(changeset.changes, :smtp_password)
        assert changeset.params["smtp_password"] == ""
      end

      assert Mail.settings() == nil
      refute_received {:sent, _email, _config}
    end

    test "saved, and the test link not sent: the settings are kept, and say so", %{scope: scope} do
      put_env(Mail, smtp_adapter: Refusing)

      assert {:ok, _settings, :not_sent} = Mail.save_settings(scope, @attrs, &url/1)
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

      assert Mail.settings() == nil
    end

    test "is refused while the environment sets mail, which wins whole", %{scope: scope} do
      put_env(Apiary.Mailer, adapter: Swoosh.Adapters.Test)

      assert Mail.save_settings(scope, @attrs, &url/1) == {:error, :env}
      assert Mail.settings() == nil
    end

    @tag with_features: [:observability, :security]
    test "is refused on an instance without the instance_mail feature", %{scope: scope} do
      assert Mail.save_settings(scope, @attrs, &url/1) == {:error, :forbidden}
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

    test "does nothing for another instance admin, and still works for the one it was sent to",
         %{scope: scope, token: token} do
      %{scope: other} = with_env_mail(fn -> member_fixture(scope, :owner) end)
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

    test "does nothing on an instance without the instance_mail feature",
         %{scope: scope, token: token} do
      put_env(:features, Features.enabled() -- [:instance_mail])

      assert Mail.turn_on(scope, token) == :error
      assert Mail.state(row()) == :pending
    end
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

    test "not without the instance_mail feature" do
      put_env(:features, Features.enabled() -- [:instance_mail])

      assert Mail.source() == :none
      assert Mail.mailer_config() == nil
    end

    test "the Backup guide says the saved password cannot be read, not that a secret turns mail off" do
      # Another APIARY_ENCRYPTION_SECRET stops the boot (`Apiary.KeyCheck`): it never
      # leaves an instance running with mail off.
      guide = "guides/backup.md" |> File.read!() |> String.split() |> Enum.join(" ")
      refute guide =~ "without it, mail from those settings is off"
      assert guide =~ "Where that saved password cannot be read, mail from those settings is off"
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
