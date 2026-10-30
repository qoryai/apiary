defmodule Apiary.Mail do
  @moduledoc """
  Whether this instance sends email, and where its mail settings come from. Every email
  goes through `Apiary.Accounts.UserNotifier`, which asks here first, and sends nothing
  when no mail is set.

  **The source** (`source/0`):

  | Source | Meaning |
  |---|---|
  | `:env` | The application's environment sets the mailer's adapter. In production that is `SMTP_RELAY` and the variables beside it, read by `config/runtime.exs`; in development the Swoosh local adapter, and in the tests the Swoosh test adapter. |
  | `:settings` | The settings an instance admin saved in Instance settings › Mail, once that admin followed the test link the save sent, and while their password can be read. |
  | `:none` | No mail is set. |

  The environment wins whole: with `SMTP_RELAY` set, the saved settings are not used, and
  Instance settings › Mail shows the environment's, read only. `configured?/0` is true for
  `:env` and `:settings`. A production release without either starts all the same, and
  says once, at `info`, that no mail is set (`boot/0`).

  **The saved settings** (`Apiary.Mail.Settings`) are in the instance's row of
  `instance_settings`, the password encrypted (`Apiary.Mail.Password`). Their state
  (`stored/0`):

  | State | Meaning |
  |---|---|
  | `:none` | Nothing saved. |
  | `:pending` | Saved; mail is off until the admin who saved them follows the test link. |
  | `:on` | Saved and followed: the source is `:settings`. |
  | `:unreadable` | Saved with a password the instance cannot read, such as a row changed outside the application: mail is off until an admin enters it again. |

  Each node keeps a copy (`Apiary.Mail.Cache`), read again over `Apiary.PubSub` whenever
  they change.

  **Saving** (`save_settings/3`), for an instance admin who signed in recently
  (`Apiary.Accounts.sudo_mode?/2`), sets the state back to `:pending` and sends a test link
  to the admin who saved, through the settings saved. While the state is `:pending`, that
  admin can send the test link again (`resend_test_link/2`), which changes no setting.
  Each test send keeps when it ran, its result (`t:test_result/0`) and the relay's reply
  code in the row, never the relay's reply text; the instance sends at most one test link
  a minute (`test_send_seconds/0`), by a save or sent again. **The test link** (`turn_on/2`)
  works once, for 60 minutes (`test_link_minutes/0`), and only for that admin, signed in,
  recently too: it turns mail on and confirms their address, and ends every password link
  an instance admin made while no mail was set (`end_password_links/0`), as a start with
  mail set by the environment does (`boot/0`). It signs no one in and changes no password. From anyone else it does nothing. It is stored as
  the SHA-256 hash of its 32 random bytes, in `users_tokens` under the context
  `"instance_mail"`, so a reader of the database cannot follow it; a later save, a change
  of the admin's address or password, a test link sent again, and its use each end it.
  Each save is an `instance.mail_save` entry in the trail of the instance's organisation,
  each test link sent again an `instance.mail_resend`, and each test link followed an
  `instance.mail_on`, by the admin, never with the password.

  **The test seam.** `put_test_source/1` sets the source for the calling process and the
  processes it starts that keep it among their `$callers` (a `Task`, a LiveView under
  test), and for no other process, so tests that set different sources run at once
  (`async: true`). Under it, an email that is sent still goes through the application's
  configured adapter, the Swoosh test adapter in the tests.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query

  require Logger

  alias Apiary.{Access, Accounts, Audit, Repo}
  alias Apiary.Accounts.{Scope, User, UserNotifier, UserToken}
  alias Apiary.Organisations.Organisation
  alias Apiary.Mail.{Cache, Password, Settings, TLS}

  @typedoc "Where the mail settings come from."
  @type source :: :env | :settings | :none

  @typedoc "The state of the saved settings; see the module's documentation."
  @type state :: :none | :pending | :on | :unreadable

  @typedoc "The saved settings with their state, `nil` where there is no row."
  @type stored :: {state, Settings.t() | nil}

  @typedoc """
  The result of a test send (`test_result/2`): `:sent`, the relay accepted the email; else
  where the send failed: `:connect`, the connection to the relay; `:tls`, TLS; `:login`,
  the log-in to the relay; `:sender`, the relay refused the sender address; `:rejected`,
  the relay refused the email otherwise; `:temporary`, the relay returned a temporary
  error; `:other`, anything else.
  """
  @type test_result ::
          :sent | :connect | :tls | :login | :sender | :rejected | :temporary | :other

  @typedoc """
  A test send, as a save and `resend_test_link/2` return it: when it ran, its result, the
  relay's reply code, such as `"550 5.7.1"`, where the result has one, and, for
  `:connect`, why the connection failed, such as `:econnrefused`, which is not stored.
  """
  @type test_send :: %{
          sent_at: DateTime.t(),
          result: test_result,
          reply_code: String.t() | nil,
          reason: atom | nil
        }

  @test_source {__MODULE__, :test_source}

  # The test link: its context in `users_tokens`, and how long it works.
  @token_context "instance_mail"
  @test_link_minutes 60

  # At most one test send in this many seconds, by a save or sent again.
  @test_send_seconds 60

  @no_mail "No mail is set: invitations and password links are copied by hand. Set mail in Instance settings › Mail."

  @doc "Whether this instance sends email: its source is not `:none`."
  @spec configured?() :: boolean
  def configured?, do: source() != :none

  @doc "Where this instance's mail settings come from; see the module's documentation."
  @spec source() :: source
  def source do
    case test_source() do
      # The saved settings are read only where the environment sets no mail.
      nil -> if env_source(env()) == :env, do: :env, else: resolve(:none, stored())
      source -> source
    end
  end

  @doc """
  resolve/2 is the source, given the environment's (`env_source/1`) and the saved
  settings (`stored/0`): the environment wins whole; then the saved settings, while they
  are on; else `:none`.
  """
  @spec resolve(:env | :none, stored) :: source
  def resolve(:env, _stored), do: :env

  def resolve(:none, {:on, %Settings{}}), do: :settings

  def resolve(:none, _stored), do: :none

  @doc """
  The configuration to send an email with, for `Apiary.Mailer.deliver/2`, or `nil` when no
  mail is set: the application's environment for `Apiary.Mailer`, whose adapter is set; or
  the saved settings', with their password decrypted for the call (`smtp_config/2`). Under
  `put_test_source/1`, the application's environment for every source but `:none`.
  """
  @spec mailer_config() :: keyword | nil
  def mailer_config do
    case {test_source(), source()} do
      {_test, :none} -> nil
      {nil, :settings} -> stored() |> elem(1) |> settings_config()
      {_test, _set} -> env()
    end
  end

  @doc """
  The address every email is sent from: the saved sender while the source is the saved
  settings and they name one, else the default (`default_sender/0`).
  """
  @spec sender() :: String.t() | nil
  def sender do
    with nil <- test_source(),
         :settings <- source(),
         {:on, %Settings{mail_from: from}} when is_binary(from) <- stored() do
      from
    else
      _other -> default_sender()
    end
  end

  @doc """
  The sender when the saved settings name none: `config :apiary, :mail_from`, which
  production sets from `MAIL_FROM`, by default `qory@<public host>`; `nil` where it is not
  set (`Apiary.Mailer.from/0`).
  """
  @spec default_sender() :: String.t() | nil
  def default_sender, do: Application.get_env(:apiary, :mail_from)

  @doc """
  The mailer's configuration from the application's environment, as `config/runtime.exs`
  reads `SMTP_RELAY` and the variables beside it.
  """
  @spec env() :: keyword
  def env, do: Application.get_env(:apiary, Apiary.Mailer, [])

  @doc """
  Sets the source `source/0` answers in the calling process and the processes that have it
  among their `$callers`, for a test. Returns `:ok`.
  """
  @spec put_test_source(source) :: :ok
  def put_test_source(source) when source in [:env, :settings, :none] do
    Process.put(@test_source, source)
    :ok
  end

  @doc """
  Says once, at `info`, that no mail is set, when none is; where mail is set, ends every
  password link an instance admin made (`end_password_links/0`), as turning mail on does:
  set by the environment, mail is read only as the node starts, so a start with
  `SMTP_RELAY` is where it turns on. The node's `Apiary.Mail.Cache` calls it once it has
  read the saved settings, before anything serves.
  """
  @spec boot() :: :ok
  def boot do
    case source() do
      :none -> Logger.info(@no_mail)
      _set -> end_password_links()
    end

    :ok
  end

  @doc """
  end_password_links/0 ends every password link an instance admin made while no mail was
  set (`Apiary.Accounts.build_password_link/3`, the context `"password"`): with mail, the
  person asks for a log-in link instead. A release command's link (`"password:release"`)
  is made mail or not, on purpose, for an hour, and is kept. Returns how many it ended.
  """
  @spec end_password_links() :: non_neg_integer
  def end_password_links do
    {ended, _} = Repo.delete_all(from t in UserToken, where: t.context == "password")
    ended
  end

  @doc false
  # The source the application's environment gives: `:env` when it names the mailer's
  # adapter, `:none` otherwise. `config/runtime.exs` sets the adapter to `nil` in
  # production without `SMTP_RELAY`.
  @spec env_source(keyword) :: :env | :none
  def env_source(mailer) do
    if mailer[:adapter], do: :env, else: :none
  end

  ## The saved settings

  @doc """
  stored/0 is the saved settings with their state, as this node's `Apiary.Mail.Cache`
  holds them, or as the database has them now where no cache runs.
  """
  @spec stored() :: stored
  def stored do
    case Cache.cached() do
      {:ok, stored} -> stored
      :error -> load()
    end
  end

  @doc "load/0 reads the saved settings and their state from the database (`stored/0`)."
  @spec load() :: stored
  def load do
    settings = settings()
    {state(settings), settings}
  end

  @doc """
  settings/0 is the instance's row of mail settings as the database has it now, `nil` for
  no row, and on a schema whose migration of the mail settings has not run yet.
  """
  @spec settings() :: Settings.t() | nil
  def settings do
    Repo.get(Settings, true)
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: :undefined_column} -> nil
        _other -> reraise error, __STACKTRACE__
      end
  end

  @doc """
  shown/0 is the saved settings as a page shows them, read from the database now
  (`settings/0`): `settings`, the row without its password
  (`Apiary.Mail.Settings.without_password/1`), `nil` for none; their `state`
  (`state/1`); and `password_saved`, whether a saved password can be read. Nothing of the
  password, which only this module decrypts, reaches the page.
  """
  @spec shown() :: %{settings: Settings.t() | nil, state: state, password_saved: boolean}
  def shown do
    settings = settings()

    %{
      settings: settings && Settings.without_password(settings),
      state: state(settings),
      password_saved: match?({:ok, _password}, settings && Password.decrypt(settings))
    }
  end

  @doc """
  sent_or_on?/1 is whether `settings`, the row as `settings/0` reads it, are on, or wait
  for a test link that the relay accepted on the last test send: the mail step of the
  instance's connections is done then. False for none.
  """
  @spec sent_or_on?(Settings.t() | nil) :: boolean
  def sent_or_on?(settings) do
    case state(settings) do
      :on -> true
      :pending -> settings.mail_test_result == :sent
      _other -> false
    end
  end

  @doc "state/1 is the state of `settings`; see the module's documentation."
  @spec state(Settings.t() | nil) :: state
  def state(nil), do: :none
  def state(%Settings{smtp_relay: nil}), do: :none

  def state(%Settings{} = settings) do
    cond do
      Password.decrypt(settings) == :error -> :unreadable
      is_nil(settings.mail_verified_at) -> :pending
      true -> :on
    end
  end

  @doc """
  smtp_config/2 is the mailer's configuration for `settings` with `password`, `nil` for
  none, as `config/runtime.exs` makes it from `SMTP_RELAY` and the variables beside it:
  port 465 is TLS from the start, any other STARTTLS as `smtp_tls` says; a username means
  logging in. TLS checks the relay's certificate, and the relay is the host connected to
  (`Apiary.Mail.TLS.smtp_options/2`). Its adapter is `Swoosh.Adapters.SMTP`, or the one
  `config :apiary, Apiary.Mail, smtp_adapter:` names, which the tests set.
  """
  @spec smtp_config(Settings.t(), String.t() | nil) :: keyword
  def smtp_config(%Settings{smtp_port: port, smtp_username: username} = settings, password) do
    implicit_tls = port == 465

    # The username and password only with a username: the adapter refuses either as nil.
    credentials = if username, do: [username: username, password: password || ""], else: []

    [
      adapter: smtp_adapter(),
      relay: settings.smtp_relay,
      port: port,
      auth: if(username, do: :always, else: :never),
      ssl: implicit_tls,
      tls: if(implicit_tls, do: :never, else: tls(settings.smtp_tls)),
      retries: 2
    ] ++ credentials ++ TLS.smtp_options(settings.smtp_relay, implicit_tls)
  end

  defp tls("always"), do: :always
  defp tls("if_available"), do: :if_available
  defp tls("never"), do: :never

  defp smtp_adapter do
    Keyword.get(
      Application.get_env(:apiary, __MODULE__, []),
      :smtp_adapter,
      Swoosh.Adapters.SMTP
    )
  end

  # The configuration of saved settings, with their password decrypted for this call; nil
  # when it no longer decrypts.
  defp settings_config(%Settings{} = settings) do
    case Password.decrypt(settings) do
      {:ok, password} -> smtp_config(settings, password)
      :none -> smtp_config(settings, nil)
      :error -> nil
    end
  end

  defp settings_config(nil), do: nil

  @doc """
  save_settings/3 saves the mail settings `attrs` (`Apiary.Mail.Settings.changeset/2`)
  for the instance admin of `scope`, and sends them a test link, made with `url_fun`, a
  function of the link's token, through the settings saved.

  The password: given, it is encrypted for the settings saved (`Apiary.Mail.Password`).
  Left empty, the saved one is kept while the relay, the port, TLS and the username stay
  as they were and it can be read; otherwise it is asked for again, unless there is no
  username, where no password is kept. A password needs a username.

  The save sets the state to `:pending`, ends every test link sent before, and broadcasts
  the change to every node's cache. It is an `instance.mail_save` entry in the trail of the
  instance's organisation, by the admin, about the organisation: the relay, the port, TLS,
  and whether a username and a sender are set, never the password, the username or the
  sender's address. The entry is written before the test send and never changed: the
  test send's result and reply code are kept in the row
  (`t:test_send/0`); a link the relay did not accept is ended.

  Returns `{:ok, settings, test_send}`, the settings saved whether the test link was sent
  or not; `{:error, changeset}`, without a password, given or saved
  (`Apiary.Mail.Settings.without_password/1`); `{:error, {:throttled, at}}` within
  #{@test_send_seconds} seconds of the last test send, which saves nothing, with `at` the
  time a test send is allowed again; `{:error, :env}` while the environment sets mail,
  which wins whole; `{:error, :sudo}` for an instance admin who did not sign in recently
  (`Apiary.Accounts.sudo_mode?/2`), who signs in again first; or `{:error, :forbidden}`
  for anyone but an instance admin.
  """
  @spec save_settings(Scope.t(), map, (String.t() -> String.t())) ::
          {:ok, Settings.t(), test_send}
          | {:error, Ecto.Changeset.t() | {:throttled, DateTime.t()} | :env | :sudo | :forbidden}
  def save_settings(%Scope{user: %User{} = user} = scope, attrs, url_fun)
      when is_map(attrs) and is_function(url_fun, 1) do
    cond do
      not Access.instance_admin?(scope) -> {:error, :forbidden}
      not Accounts.sudo_mode?(user) -> {:error, :sudo}
      source() == :env -> {:error, :env}
      true -> save(scope, attrs, url_fun)
    end
  end

  def save_settings(_scope, _attrs, _url_fun), do: {:error, :forbidden}

  defp save(%Scope{user: user} = scope, attrs, url_fun) do
    Repo.transact(fn ->
      current = lock_row()
      changeset = current |> Settings.changeset(attrs) |> put_password(current)
      now = DateTime.utc_now()

      with true <- changeset.valid? || {:error, Settings.without_password(changeset)},
           :ok <- throttle(current, now),
           {:ok, organisation} <- instance_organisation() do
        settings =
          changeset
          |> Ecto.Changeset.delete_change(:smtp_password)
          |> Ecto.Changeset.change(
            mail_saved_at: now,
            mail_saved_by_id: user.id,
            mail_verified_at: nil,
            updated_at: now
          )
          |> start_test_send(now)
          |> Repo.update!()

        token = new_test_link(user)

        with {:ok, _entry} <-
               Audit.record(
                 Repo,
                 Scope.in_organisation(scope, organisation),
                 :"instance.mail_save",
                 organisation,
                 %{details: saved_details(settings)}
               ),
             do: {:ok, {settings, token}}
      end
    end)
    |> case do
      {:ok, {settings, token}} ->
        Cache.changed()
        settings = %{settings | smtp_password: nil}
        test_send = send_test_link(settings, user, token, url_fun.(token))
        record_test_send(test_send)

        {:ok,
         %{
           settings
           | mail_test_result: test_send.result,
             mail_test_reply_code: test_send.reply_code
         }, test_send}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  resend_test_link/2 sends the test link again to the instance admin of `scope`, made with
  `url_fun` as `save_settings/3` makes it, through the settings saved: for the admin who
  saved them, after a recent sign-in, while their state is `:pending`. In one transaction,
  with the row locked, it ends every test link sent before and makes a new one; it changes
  no setting. The send's result and reply code are kept in the row, as a save's are, and
  are an `instance.mail_resend` entry in the trail of the instance's organisation, by the
  admin, about the organisation, with the result and the reply code alone.

  Returns `{:ok, test_send}`, sent or not (`t:test_send/0`); `{:error, {:throttled, at}}`
  within #{@test_send_seconds} seconds of the last test send, with `at` the time a test
  send is allowed again; `{:error, :not_pending}` where the state is not `:pending`;
  `{:error, :not_saver}` for an instance admin who did not save the settings;
  `{:error, :env}` while the environment sets mail; `{:error, :sudo}` for an instance admin
  who did not sign in recently; or `{:error, :forbidden}` for anyone but an instance
  admin. Each error sends nothing and changes nothing.
  """
  @spec resend_test_link(Scope.t() | nil, (String.t() -> String.t())) ::
          {:ok, test_send}
          | {:error,
             {:throttled, DateTime.t()}
             | :not_pending
             | :not_saver
             | :env
             | :sudo
             | :forbidden}
  def resend_test_link(%Scope{user: %User{} = user} = scope, url_fun)
      when is_function(url_fun, 1) do
    cond do
      not Access.instance_admin?(scope) -> {:error, :forbidden}
      not Accounts.sudo_mode?(user) -> {:error, :sudo}
      source() == :env -> {:error, :env}
      true -> resend(scope, url_fun)
    end
  end

  def resend_test_link(_scope, _url_fun), do: {:error, :forbidden}

  defp resend(%Scope{user: user} = scope, url_fun) do
    Repo.transact(fn ->
      settings = Repo.one(from s in Settings, where: s.id == true, lock: "FOR UPDATE")
      now = DateTime.utc_now()

      with :ok <- resendable(settings, user),
           :ok <- throttle(settings, now),
           {:ok, organisation} <- instance_organisation() do
        settings = settings |> start_test_send(now) |> Repo.update!()
        {:ok, {settings, organisation, new_test_link(user)}}
      end
    end)
    |> case do
      {:ok, {settings, organisation, token}} ->
        test_send = send_test_link(settings, user, token, url_fun.(token))

        Repo.transact(fn ->
          record_test_send(test_send)

          Audit.record(
            Repo,
            Scope.in_organisation(scope, organisation),
            :"instance.mail_resend",
            organisation,
            %{details: %{result: test_send.result, reply_code: test_send.reply_code}}
          )
        end)
        |> case do
          {:ok, _entry} -> {:ok, test_send}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  # Whether `user` may send the test link of `settings` again: they saved them, and the
  # settings wait for the test link.
  defp resendable(%Settings{mail_saved_by_id: saved_by} = settings, %User{id: user_id}) do
    cond do
      state(settings) != :pending -> {:error, :not_pending}
      saved_by != user_id -> {:error, :not_saver}
      true -> :ok
    end
  end

  defp resendable(nil, _user), do: {:error, :not_pending}

  @doc "test_send_seconds/0 is the time between two test sends, at least: #{@test_send_seconds} seconds."
  @spec test_send_seconds() :: pos_integer
  def test_send_seconds, do: @test_send_seconds

  # `:ok` where the last test send ran at least `test_send_seconds/0` before `now`, else
  # the time a test send is allowed again. Read under the row's lock, so two nodes
  # never both send.
  defp throttle(%Settings{mail_test_sent_at: %DateTime{} = sent_at}, now) do
    allowed_at = DateTime.add(sent_at, @test_send_seconds, :second)
    if DateTime.before?(now, allowed_at), do: {:error, {:throttled, allowed_at}}, else: :ok
  end

  defp throttle(_settings, _now), do: :ok

  # A test send starts at `now`: its result is not known yet.
  defp start_test_send(settings_or_changeset, now) do
    Ecto.Changeset.change(settings_or_changeset,
      mail_test_sent_at: now,
      mail_test_result: nil,
      mail_test_reply_code: nil
    )
  end

  # Ends every test link sent before, and makes one for `user`: its token.
  defp new_test_link(user) do
    Repo.delete_all(from t in UserToken, where: t.context == @token_context)
    {token, user_token} = UserToken.build_email_token(user, @token_context)
    Repo.insert!(user_token)
    token
  end

  # Keeps a test send's result in the row, unless a later test send has started since.
  defp record_test_send(%{sent_at: sent_at, result: result, reply_code: reply_code}) do
    Repo.update_all(
      from(s in Settings, where: s.id == true and s.mail_test_sent_at == ^sent_at),
      set: [mail_test_result: result, mail_test_reply_code: reply_code]
    )
  end

  # What the trail says of settings saved: never the password, the username or the
  # sender's address, which may be a person's.
  defp saved_details(%Settings{} = settings) do
    %{
      relay: settings.smtp_relay,
      port: settings.smtp_port,
      tls: settings.smtp_tls,
      username: is_binary(settings.smtp_username),
      sender: is_binary(settings.mail_from)
    }
  end

  # The instance's own organisation, whose trail holds the mail's entries; its owners are
  # the instance's admins.
  defp instance_organisation do
    with id when is_binary(id) <- Apiary.Edition.instance_organisation_id(),
         %Organisation{} = organisation <- Repo.get(Organisation, id) do
      {:ok, organisation}
    else
      _none -> {:error, :forbidden}
    end
  end

  # The row, locked for the save, made where there is none yet.
  defp lock_row do
    Repo.insert_all("instance_settings", [%{id: true, updated_at: DateTime.utc_now()}],
      on_conflict: :nothing,
      conflict_target: :id
    )

    Repo.one!(from s in Settings, where: s.id == true, lock: "FOR UPDATE")
  end

  # The password the save keeps: the one given, encrypted for the settings saved; the one
  # saved, where nothing it is bound to changed and it can be read; none without a
  # username.
  defp put_password(%Ecto.Changeset{valid?: false} = changeset, _current), do: changeset

  defp put_password(changeset, current) do
    given = Ecto.Changeset.get_change(changeset, :smtp_password)
    next = Ecto.Changeset.apply_changes(changeset)

    cond do
      is_nil(next.smtp_username) and is_binary(given) ->
        Ecto.Changeset.add_error(
          changeset,
          :smtp_username,
          dgettext_noop("errors", "can't be blank with a password")
        )

      is_nil(next.smtp_username) ->
        Ecto.Changeset.change(changeset, smtp_password_ciphertext: nil, mail_key_id: nil)

      is_binary(given) ->
        {ciphertext, key_id} = Password.encrypt(next, given)

        Ecto.Changeset.change(changeset,
          smtp_password_ciphertext: ciphertext,
          mail_key_id: key_id
        )

      not is_binary(current.smtp_password_ciphertext) ->
        Ecto.Changeset.add_error(
          changeset,
          :smtp_password,
          dgettext_noop("errors", "can't be blank")
        )

      not bound_alike?(current, next) ->
        Ecto.Changeset.add_error(
          changeset,
          :smtp_password,
          dgettext_noop("errors", "enter it again: the relay, port, TLS or username changed")
        )

      match?({:ok, _password}, Password.decrypt(current)) ->
        changeset

      true ->
        Ecto.Changeset.add_error(
          changeset,
          :smtp_password,
          dgettext_noop("errors", "enter it again: the saved one cannot be read")
        )
    end
  end

  # Whether nothing the saved password is bound to changed.
  defp bound_alike?(current, next) do
    Enum.all?(
      [:smtp_relay, :smtp_port, :smtp_tls, :smtp_username],
      &(Map.fetch!(current, &1) == Map.fetch!(next, &1))
    )
  end

  # Sends the test link through the settings saved, whatever the source is: the test send
  # (`t:test_send/0`). A link the relay did not accept is ended, so none waits, and is one
  # log line, with the result and the reply code alone: no host and no address.
  defp send_test_link(settings, user, token, url) do
    {result, reply_code, reason} =
      case settings_config(settings) do
        config when is_list(config) -> deliver_test_link(user, url, config, settings.mail_from)
        nil -> {:other, nil, nil}
      end

    if result != :sent do
      {:ok, decoded} = Base.url_decode64(token, padding: false)
      hashed = :crypto.hash(:sha256, decoded)

      Repo.delete_all(
        from t in UserToken, where: t.context == @token_context and t.token == ^hashed
      )

      Logger.warning(
        "The test link of the mail settings was not sent: #{result}" <>
          if(reply_code, do: ", reply code #{reply_code}", else: "")
      )
    end

    %{sent_at: settings.mail_test_sent_at, result: result, reply_code: reply_code, reason: reason}
  end

  # Delivers the test link, and classes the answer (`test_result/2`). gen_smtp's error has
  # no field for the command the relay refused; its trace function is called with the
  # format below only when the relay refuses MAIL FROM, the sender address. An exception from the
  # adapter is the result `:other`.
  defp deliver_test_link(user, url, config, sender) do
    ref = make_ref()
    caller = self()

    trace = fn
      ~c"Mail FROM rejected: ~p~n", _args -> send(caller, {ref, :mail_from})
      _format, _args -> :ok
    end

    answer =
      try do
        UserNotifier.deliver_mail_test_link(user, url, config ++ [trace_fun: trace], sender)
      rescue
        _exception -> {:error, :exception}
      catch
        _kind, _reason -> {:error, :exception}
      end

    mail_from_refused =
      receive do
        {^ref, :mail_from} -> true
      after
        0 -> false
      end

    test_result(answer, mail_from_refused)
  end

  @doc """
  test_result/2 is the result of a test send (`t:test_result/0`) as `{result, reply_code,
  reason}`, from `answer`, what `Apiary.Mailer.deliver/2` returned through
  `Swoosh.Adapters.SMTP`, which wraps gen_smtp's `{error, Type, Failure}` as
  `{:error, {type, failure}}`. `mail_from_refused` is whether the relay refused the MAIL
  FROM command, which only gen_smtp's trace shows.

  - A network failure is `:connect`, with its reason, such as `:econnrefused`; a TLS
    alert while it connects, on port 465, is `:tls`.
  - A STARTTLS that failed, or that the relay does not offer while TLS is Always, is
    `:tls`.
  - A log-in the relay refused, or one it does not offer while a username is set, is
    `:login`. gen_smtp keeps no reply code for it.
  - A reply 5xx is `:sender` where the relay refused MAIL FROM, else `:rejected`; a reply
    4xx is `:temporary`. Each keeps the reply code and the enhanced status code, such as
    `"550 5.7.1"`.
  - Anything else is `:other`, as is a reply without a code.
  """
  @spec test_result(term, boolean) :: {test_result, String.t() | nil, atom | nil}
  def test_result({:ok, _sent}, _mail_from_refused), do: {:sent, nil, nil}

  def test_result({:error, {type, failure}}, mail_from_refused) when is_tuple(failure),
    do: failure_result(type, failure, mail_from_refused)

  def test_result(_answer, _mail_from_refused), do: {:other, nil, nil}

  defp failure_result(_type, {:network_failure, _host, {:error, {:tls_alert, _alert}}}, _from),
    do: {:tls, nil, nil}

  defp failure_result(_type, {:network_failure, _host, {:error, reason}}, _from)
       when is_atom(reason),
       do: {:connect, nil, reason}

  defp failure_result(_type, {:network_failure, _host, _error}, _from), do: {:connect, nil, nil}

  defp failure_result(_type, {:temporary_failure, _host, :tls_failed}, _from),
    do: {:tls, nil, nil}

  defp failure_result(_type, {:missing_requirement, _host, :tls}, _from), do: {:tls, nil, nil}

  defp failure_result(_type, {:permanent_failure, _host, :auth_failed}, _from),
    do: {:login, nil, nil}

  defp failure_result(_type, {:missing_requirement, _host, :auth}, _from), do: {:login, nil, nil}

  defp failure_result(type, {:permanent_failure, _host, reply}, mail_from_refused)
       when is_binary(reply) do
    case reply_code(reply) do
      "5" <> _rest = code when type == :send and mail_from_refused -> {:sender, code, nil}
      "5" <> _rest = code -> {:rejected, code, nil}
      _other -> {:other, nil, nil}
    end
  end

  defp failure_result(_type, {:temporary_failure, _host, reply}, _from) when is_binary(reply) do
    case reply_code(reply) do
      "4" <> _rest = code -> {:temporary, code, nil}
      _other -> {:other, nil, nil}
    end
  end

  defp failure_result(_type, _failure, _from), do: {:other, nil, nil}

  # The reply code of a relay's reply, with its enhanced status code where the reply
  # starts with one: "550 5.7.1" of "550 5.7.1 Sender not allowed". Nothing else of the
  # reply, which can contain the relay's host and this server's IP address.
  defp reply_code(reply) do
    case Regex.run(~r/\A([2-5][0-9]{2})[ -](?:([245]\.[0-9]{1,3}\.[0-9]{1,3})(?![0-9.]))?/, reply) do
      [_reply, code, enhanced] -> code <> " " <> enhanced
      [_reply, code] -> code
      nil -> nil
    end
  end

  @doc """
  test_link_waiting?/1 is whether the settings saved, `settings`, still wait on a test link
  that can turn them on: one sent to the admin who saved them, to their current address,
  less than #{@test_link_minutes} minutes ago. False for settings already on, or for none.
  """
  @spec test_link_waiting?(Settings.t() | nil) :: boolean
  def test_link_waiting?(%Settings{
        smtp_relay: relay,
        mail_verified_at: nil,
        mail_saved_by_id: user_id
      })
      when is_binary(relay) and is_binary(user_id) do
    Repo.exists?(
      from t in UserToken,
        join: u in assoc(t, :user),
        where: t.context == @token_context and t.user_id == ^user_id,
        where: t.sent_to == u.email and is_nil(u.deleted_at),
        where: t.inserted_at > ago(^@test_link_minutes, "minute")
    )
  end

  def test_link_waiting?(_settings), do: false

  @doc "test_link_minutes/0 is how long a test link works: #{@test_link_minutes} minutes."
  @spec test_link_minutes() :: pos_integer
  def test_link_minutes, do: @test_link_minutes

  @doc """
  turn_on/2 follows the test link whose token is `token` for the person of `scope`: where
  they are an instance admin, saved the settings that are waiting, and the link is the one
  sent to them, to their current address, within #{@test_link_minutes} minutes, it turns
  mail on, confirms their address where it was not yet, ends the link and every password
  link an instance admin made while no mail was set (`end_password_links/0`), and is an
  `instance.mail_on` entry in the trail of the instance's organisation, by the admin, in
  one transaction, then broadcasts the change to every node's cache. It signs no one in
  and changes no password. `{:ok, settings}`; `{:error, :sudo}` for an instance admin who
  did not sign in recently (`Apiary.Accounts.sudo_mode?/2`), which changes nothing, so the
  link still works once they sign in again; or `:error` for any other link or person,
  which changes nothing: the link still works for the admin it was sent to.
  """
  @spec turn_on(Scope.t() | nil, String.t()) :: {:ok, Settings.t()} | {:error, :sudo} | :error
  def turn_on(%Scope{user: %User{} = user} = scope, token) when is_binary(token) do
    with {:ok, decoded} <- Base.url_decode64(token, padding: false),
         true <- Access.instance_admin?(scope),
         true <- Accounts.sudo_mode?(user) || {:error, :sudo},
         {:ok, settings} <- turn_on_now(scope, :crypto.hash(:sha256, decoded)) do
      Cache.changed()
      {:ok, settings}
    else
      {:error, :sudo} = sudo -> sudo
      _not_turned_on -> :error
    end
  end

  def turn_on(_scope, _token), do: :error

  defp turn_on_now(%Scope{user: %User{id: user_id}} = scope, hashed) do
    Repo.transact(fn ->
      settings = Repo.one(from s in Settings, where: s.id == true, lock: "FOR UPDATE")

      user_token =
        Repo.one(
          from t in UserToken,
            join: u in assoc(t, :user),
            where: t.token == ^hashed and t.context == @token_context,
            where: t.user_id == ^user_id and t.sent_to == u.email and is_nil(u.deleted_at),
            where: t.inserted_at > ago(^@test_link_minutes, "minute"),
            preload: [user: u]
        )

      with {%Settings{smtp_relay: relay, mail_verified_at: nil, mail_saved_by_id: ^user_id},
            %UserToken{user: user}}
           when is_binary(relay) <- {settings, user_token},
           {:ok, organisation} <- instance_organisation() do
        Repo.delete!(user_token)
        if is_nil(user.confirmed_at), do: user |> User.confirm_changeset() |> Repo.update!()
        password_links = end_password_links()
        now = DateTime.utc_now()

        settings =
          settings
          |> Ecto.Changeset.change(mail_verified_at: now, updated_at: now)
          |> Repo.update!()

        with {:ok, _entry} <-
               Audit.record(
                 Repo,
                 Scope.in_organisation(scope, organisation),
                 :"instance.mail_on",
                 organisation,
                 %{
                   details: %{
                     relay: settings.smtp_relay,
                     port: settings.smtp_port,
                     password_links_ended: password_links
                   }
                 }
               ),
             do: {:ok, settings}
      else
        {:error, _reason} = error -> error
        _other -> {:error, :invalid}
      end
    end)
  end

  ## The test seam

  # The source a test set in this process, or in the nearest of its callers that set one.
  defp test_source do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn
      pid when pid == self() -> Process.get(@test_source)
      pid -> caller_source(pid)
    end)
  end

  defp caller_source(pid) do
    case Process.info(pid, {:dictionary, @test_source}) do
      {{:dictionary, @test_source}, source} when source in [:env, :settings, :none] -> source
      _unset_or_gone -> nil
    end
  end
end
