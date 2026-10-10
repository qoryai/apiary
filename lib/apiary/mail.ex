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
  to the admin who saved, through the settings saved. **The test link** (`turn_on/2`)
  works once, for 60 minutes (`test_link_minutes/0`), and only for that admin, signed in,
  recently too: it turns mail on and confirms their address. It signs no one in and
  changes no password. From anyone else it does nothing. It is stored as
  the SHA-256 hash of its 32 random bytes, in `users_tokens` under the context
  `"instance_mail"`, so a reader of the database cannot follow it; a later save, a change
  of the admin's address or password, and its use each end it. Each save is an
  `instance.mail_save` entry in the trail of the instance's organisation, and each test
  link followed an `instance.mail_on`, by the admin, never with the password.

  **The test seam.** `put_test_source/1` sets the source for the calling process and the
  processes it starts that keep it among their `$callers` (a `Task`, a LiveView under
  test), and for no other process, so tests that set different sources run at once
  (`async: true`). Under it, an email that is sent still goes through the application's
  own adapter, the Swoosh test adapter in the tests.
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

  @test_source {__MODULE__, :test_source}

  # The test link: its context in `users_tokens`, and how long it works.
  @token_context "instance_mail"
  @test_link_minutes 60

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
  Says once, at `info`, that no mail is set, when none is. The node's `Apiary.Mail.Cache`
  calls it once it has read the saved settings, before anything serves.
  """
  @spec boot() :: :ok
  def boot do
    if source() == :none, do: Logger.info(@no_mail)
    :ok
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
  sender's address. Returns `{:ok, settings, :sent}`, or
  `{:ok, settings, :not_sent}` when the test link could not be sent through them, the
  settings saved all the same; `{:error, changeset}`, without the password given
  (`Apiary.Mail.Settings.without_password/1`); `{:error, :env}` while the environment
  sets mail, which wins whole; `{:error, :sudo}` for an instance admin who did not sign in
  recently (`Apiary.Accounts.sudo_mode?/2`), who signs in again first; or
  `{:error, :forbidden}` for anyone but an instance admin.
  """
  @spec save_settings(Scope.t(), map, (String.t() -> String.t())) ::
          {:ok, Settings.t(), :sent | :not_sent}
          | {:error, Ecto.Changeset.t() | :env | :sudo | :forbidden}
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

      with true <- changeset.valid? || {:error, Settings.without_password(changeset)},
           {:ok, organisation} <- instance_organisation() do
        now = DateTime.utc_now()

        settings =
          changeset
          |> Ecto.Changeset.delete_change(:smtp_password)
          |> Ecto.Changeset.change(
            mail_saved_at: now,
            mail_saved_by_id: user.id,
            mail_verified_at: nil,
            updated_at: now
          )
          |> Repo.update!()

        Repo.delete_all(from t in UserToken, where: t.context == @token_context)
        {token, user_token} = UserToken.build_email_token(user, @token_context)
        Repo.insert!(user_token)

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
        {:ok, settings, send_test_link(settings, user, token, url_fun.(token))}

      {:error, _changeset} = error ->
        error
    end
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

  # Sends the test link through the settings just saved, whatever the source is. A link
  # that could not be sent is ended, so none waits.
  defp send_test_link(settings, user, token, url) do
    with config when is_list(config) <- settings_config(settings),
         {:ok, _email} <-
           UserNotifier.deliver_mail_test_link(user, url, config, settings.mail_from) do
      :sent
    else
      _not_sent ->
        {:ok, decoded} = Base.url_decode64(token, padding: false)
        hashed = :crypto.hash(:sha256, decoded)

        Repo.delete_all(
          from t in UserToken, where: t.context == @token_context and t.token == ^hashed
        )

        :not_sent
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
  mail on, confirms their address where it was not yet, ends the link, and is an
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
                 %{details: %{relay: settings.smtp_relay, port: settings.smtp_port}}
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
