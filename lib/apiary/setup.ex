defmodule Apiary.Setup do
  @moduledoc """
  The instance's set-up link, `/setup/<code>`: the one way to make the first admin of an
  instance from a browser. Its page (`ApiaryWeb.SetupLive`) asks for an email address, a
  password and the organisation's name, and makes the instance's first account and its
  organisation, with no workspace. Until it is used nobody can sign up
  (`Apiary.Organisations.sign_up_offer/1` answers `:not_set_up`).

  **The connections.** After set-up, an instance admin is sent to the instance's
  connections, `/instance/set-up`, at every sign-in, until an instance admin finishes or
  skips its last step: `review_connections/1` sets `connections_reviewed_at` of the
  instance's row, and `connections_reviewed?/0` reads it.

  **The code.** 32 random bytes (`:crypto.strong_rand_bytes/1`) in base64url without
  padding, 43 characters. It is stored as it is in the instance's row of
  `instance_settings`, `setup_code`, until it is used; using it sets `set_up_at` and
  makes `setup_code` NULL in the same transaction that makes the account. It is not
  encrypted: whoever can read that table can already write an admin into it. A code is
  compared in constant time (`Plug.Crypto.secure_compare/2`). It does not expire before
  it is used.

  **Set up** means the instance has its organisation
  (`c:Apiary.Edition.instance_organisation_id/0`): by the link, by the release command
  (`Apiary.Release.grant_instance_admin/2`), or in a restored database.

  **At every start** before set-up, `start_link/0`, a child of the application's
  supervisor just before the endpoint, finds the stored code or makes one (`code!/0`) and
  logs the link, the same at every start until it is used:

      Set up Qory Apiary at https://qory.example.com/setup/<code>.

  That line is the only place the code is written: every other log line has it replaced
  by `:code`, a request's path among them (`Apiary.SecretLogFilter`). Once the instance is set up, a start
  finds, makes and logs nothing. Off in test (`config :apiary, Apiary.Setup, enabled:
  false`), where the tests call `boot/0` themselves.

  **A preset code.** With `QORY_SETUP_CODE_SHA256` set (`preset!/0`), the install makes
  the code and prints its link, and Qory Apiary has the code's SHA-256 alone, the preset.
  A start then makes, stores and logs no code. It sets a stored `setup_code` to NULL, so a
  link that an earlier start logged works no more, and logs a line without a link:

      Qory Apiary is not set up yet. Open the set-up link that your install printed; this log does not show it.

  The one code accepted is 43 base64url characters whose SHA-256 is the preset; the
  digests are compared in constant time, and a code of any other form is refused before
  it is hashed. The set-up, by the link or by the release command, writes the preset to
  `used_setup_code_sha256`, and a code whose SHA-256 is that column's value is refused,
  so a preset sets an instance up once. After a purge of the instance's organisation, a
  start with that preset logs, at warning:

      Set QORY_SETUP_CODE_SHA256 to the hash of a new set-up code, or unset it to get a set-up link in this log. The code it gives has set up this instance before.

  The code is never stored or logged, and the preset is not logged either.

  **The lock.** `code!/0` holds the row `FOR UPDATE` while it reads, and makes, the code,
  so of two starts at once one makes it and the other finds it. The first sign-up holds
  the instance's first-sign-up lock and then the row
  (`Apiary.Organisations.sign_up_user/3`), so of two set-ups at once one makes the
  account and the other finds the instance set up.
  """

  require Logger

  alias Apiary.Accounts.User
  alias Apiary.{Organisations, Repo}

  @code_bytes 32

  # The form of a code Qory Apiary makes: 32 bytes in base64url without padding.
  @code_form ~r/\A[A-Za-z0-9_-]{43}\z/

  @preset_line "Qory Apiary is not set up yet. Open the set-up link that your install printed; this log does not show it."

  @preset_used_line "Set QORY_SETUP_CODE_SHA256 to the hash of a new set-up code, or unset it to get a set-up link in this log. The code it gives has set up this instance before."

  @preset_refusal "Set QORY_SETUP_CODE_SHA256 to 64 hexadecimal characters, the SHA-256 of the set-up code, or leave it unset. The value set is not that."

  # The instance's own row, made when nothing has made it yet, with the columns' defaults.
  @ensure_row """
  INSERT INTO instance_settings (id, updated_at) VALUES (true, $1)
  ON CONFLICT (id) DO NOTHING
  """

  @lock_row "SELECT setup_code, used_setup_code_sha256 FROM instance_settings WHERE id FOR UPDATE"

  @doc "Starts once, as a worker the supervisor does not restart."
  @spec child_spec(term) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      restart: :temporary,
      type: :worker
    }
  end

  @doc "enabled?/0 is whether the application runs the step at boot: true unless configured off."
  @spec enabled?() :: boolean
  def enabled?, do: Keyword.get(Application.get_env(:apiary, __MODULE__, []), :enabled, true)

  @doc """
  Runs the step at boot (`boot/0`) and leaves nothing in the supervision tree: `:ignore`.
  """
  @spec start_link() :: :ignore
  def start_link do
    :ok = boot()
    :ignore
  end

  @doc """
  boot/0 logs the set-up link while the instance is not set up, the code found or made
  by `code!/0`; once it is set up it does nothing. With a preset (`preset!/0`) it makes
  no code: it sets a stored code to NULL and logs a line without a link, at warning when
  the preset has set the instance up before. `:ok`.
  """
  @spec boot() :: :ok
  def boot do
    case preset!() do
      nil -> boot_link()
      preset -> boot_preset(preset)
    end

    :ok
  end

  defp boot_link do
    case find_or_create() do
      # The one line the log filter lets the code through (`Apiary.SecretLogFilter`).
      {:ok, code} -> Logger.info(log_line(code), setup_link: true)
      :set_up -> :ok
    end
  end

  # Asked first without a lock, as `find_or_create/0` asks; then, under the row's lock, a
  # stored code is set to NULL, and the used preset is read.
  defp boot_preset(preset) do
    if set_up?() do
      :ok
    else
      {:ok, found} =
        Repo.transaction(fn ->
          {stored, used} = lock_row(Repo)

          if is_binary(stored),
            do: Repo.query!("UPDATE instance_settings SET setup_code = NULL WHERE id")

          cond do
            set_up?() -> :set_up
            used == preset -> :used
            true -> :unused
          end
        end)

      case found do
        :unused -> Logger.info(@preset_line)
        :used -> Logger.warning(@preset_used_line)
        :set_up -> :ok
      end
    end
  end

  @doc """
  preset!/0 is the SHA-256 of the preset set-up code, 32 bytes, from
  `QORY_SETUP_CODE_SHA256`: 64 hexadecimal characters in either case, spaces around them
  trimmed. nil when the variable is unset or blank. Called at boot; raises on any other
  value, so the instance does not start, with a message that does not contain the value.
  """
  @spec preset!() :: <<_::256>> | nil
  def preset! do
    case parse_preset(
           Keyword.get(Application.get_env(:apiary, __MODULE__, []), :preset_code_sha256_setting)
         ) do
      {:ok, preset} -> preset
      :error -> raise ArgumentError, @preset_refusal
    end
  end

  defp parse_preset(nil), do: {:ok, nil}

  defp parse_preset(setting) when is_binary(setting) do
    case String.trim(setting) do
      "" -> {:ok, nil}
      hex when byte_size(hex) == 64 -> Base.decode16(hex, case: :mixed)
      _other -> :error
    end
  end

  defp parse_preset(_setting), do: :error

  @doc false
  # The one line that carries the code.
  @spec log_line(String.t()) :: String.t()
  def log_line(code), do: "Set up Qory Apiary at #{link(code)}."

  @doc "link/1 is the set-up link of `code`, on the instance's address (`public_url/0`)."
  @spec link(String.t()) :: String.t()
  def link(code), do: "#{public_url()}/setup/#{code}"

  @doc "set_up?/0 says whether the instance is set up: it has its organisation."
  @spec set_up?() :: boolean
  def set_up?, do: not is_nil(Apiary.Edition.instance_organisation_id())

  @doc """
  connections_reviewed?/0 says whether an instance admin has finished or skipped the last
  step of the instance's connections, `/instance/set-up`:
  `connections_reviewed_at` of the instance's row is set. False with no row.
  """
  @spec connections_reviewed?() :: boolean
  def connections_reviewed? do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM instance_settings WHERE id AND connections_reviewed_at IS NOT NULL"
      )

    rows != []
  end

  @doc """
  review_connections/1 marks the instance's connections reviewed, for the instance admin
  of `scope` (`Apiary.Access.instance_admin?/1`): it sets `connections_reviewed_at` of the
  instance's row, made where there is none, once; a later call keeps the first time.
  `:ok`, or `{:error, :forbidden}` for anyone but an instance admin.
  """
  @spec review_connections(Apiary.Accounts.Scope.t()) :: :ok | {:error, :forbidden}
  def review_connections(scope) do
    if Apiary.Access.instance_admin?(scope) do
      now = DateTime.utc_now()
      Repo.query!(@ensure_row, [now])

      Repo.query!(
        "UPDATE instance_settings SET connections_reviewed_at = $1 " <>
          "WHERE id AND connections_reviewed_at IS NULL",
        [now]
      )

      :ok
    else
      {:error, :forbidden}
    end
  end

  @doc """
  code!/0 is the set-up code, found or made: the stored one, or else a new one, stored
  before it is returned, all under the row's lock. The same code until it is used.
  Raises once the instance is set up, when there is no code to give, and with a preset
  (`preset!/0`), when Qory Apiary makes no code.
  """
  @spec code!() :: String.t()
  def code! do
    if preset!(),
      do: raise(ArgumentError, "this Qory Apiary has a preset set-up code: it makes none")

    case find_or_create() do
      {:ok, code} -> code
      :set_up -> raise ArgumentError, "this Qory Apiary is set up already: it has no set-up code"
    end
  end

  # Asked first without a lock, so a set-up instance, a restored one among them, reads
  # nothing more; then again under the row's lock.
  defp find_or_create do
    if set_up?() do
      :set_up
    else
      {:ok, found} =
        Repo.transaction(fn ->
          {stored, _used} = lock_row(Repo)

          cond do
            set_up?() -> :set_up
            is_binary(stored) -> {:ok, stored}
            true -> {:ok, store_new_code()}
          end
        end)

      found
    end
  end

  defp store_new_code do
    code = Base.url_encode64(:crypto.strong_rand_bytes(@code_bytes), padding: false)

    # A set_up_at left by an organisation gone since: a code is unused, and a set-up
    # starts again. Not in the query log, whose debug lines print a query's parameters.
    Repo.query!(
      "UPDATE instance_settings SET setup_code = $1, set_up_at = NULL WHERE id",
      [code],
      log: false
    )

    code
  end

  # The stored code and the used preset, `{setup_code, used_setup_code_sha256}`, the row
  # held `FOR UPDATE` until the transaction ends.
  defp lock_row(repo) do
    repo.query!(@ensure_row, [DateTime.utc_now()])
    %{rows: [[stored, used]]} = repo.query!(@lock_row)
    {stored, used}
  end

  @doc """
  valid_code?/1 says whether `code` is the stored, unused set-up code, compared in
  constant time; read without a lock, for the set-up page to decide what it shows.
  `set_up/3` checks again under the lock. With a preset (`preset!/0`) it says whether
  `code` is the preset code and the preset has not set the instance up before.
  """
  @spec valid_code?(term) :: boolean
  def valid_code?(code) when is_binary(code) do
    case preset!() do
      nil -> valid_stored_code?(code)
      preset -> preset_code?(preset, read_used(), code)
    end
  end

  def valid_code?(_code), do: false

  defp valid_stored_code?(code) do
    case Repo.query!("SELECT setup_code FROM instance_settings WHERE id") do
      %{rows: [[stored]]} when is_binary(stored) -> same_code?(stored, code)
      _none -> false
    end
  end

  defp read_used do
    case Repo.query!("SELECT used_setup_code_sha256 FROM instance_settings WHERE id") do
      %{rows: [[used]]} -> used
      %{rows: []} -> nil
    end
  end

  # The one comparison of a code with the stored one, in constant time, so the time it
  # takes tells nothing of how much of the code was right.
  defp same_code?(stored, code), do: Plug.Crypto.secure_compare(stored, code)

  # A code is the preset code when it has the form of a code Qory Apiary makes, checked
  # before it is hashed, the preset is not the used one, and its SHA-256 is the preset.
  # SHA-256 of 43 bytes takes a fixed time, and the digests are compared in constant time.
  defp preset_code?(preset, used, code) do
    byte_size(code) == 43 and code =~ @code_form and used != preset and
      Plug.Crypto.secure_compare(:crypto.hash(:sha256, code), preset)
  end

  @doc """
  set_up/3 sets the instance up with `code`: the instance's first sign-up,
  `Apiary.Organisations.sign_up_user/3` with `first_only: true` and `actor: :instance`,
  in one transaction that also checks the code under the row's lock and marks it used.
  `attrs` are the sign-up form's: `email`, `organisation_name`, `password`,
  `password_confirmation`. It creates the instance's organisation, with no workspace, and
  the account as its owner, and the edition's part of a first sign-up applies
  (`:first_sign_up`). The organisation's first workspace comes later
  (`Apiary.Organisations.create_first_workspace/2`, from the workspace set-up page).

  Answers `{:ok, map}` as the sign-up does; `{:error, :already_set_up}` once the instance
  is set up, a set-up a moment before included; `{:error, :invalid_code}` for a code that
  is not the stored one, or with a preset not the preset code (`valid_code?/1`); or
  `{:error, changeset}`, the sign-up form's.

  `password: :required` asks for a password, as the set-up page does; by default it is
  required while the instance sends no email (`Apiary.Mail.configured?/0`), as a
  person's sign-up's is, and optional once it does; a password given is kept either way.
  `origin:` is where the set-up comes from, for its entry
  (`Apiary.Accounts.Scope.put_origin/2`); `Apiary.Setup` when none is given.
  """
  @spec set_up(String.t(), map, keyword) ::
          {:ok, map} | {:error, :already_set_up | :invalid_code | Ecto.Changeset.t()}
  def set_up(code, attrs, opts \\ []) when is_binary(code) and is_map(attrs) do
    cond do
      set_up?() ->
        {:error, :already_set_up}

      not valid_code?(code) ->
        {:error, :invalid_code}

      true ->
        password =
          Keyword.get_lazy(opts, :password, fn ->
            if Apiary.Mail.configured?(), do: :optional, else: :required
          end)

        case Organisations.sign_up_user(attrs, nil,
               first_only: true,
               actor: :instance,
               setup_code: code,
               password: password,
               workspace: false,
               origin: Keyword.get(opts, :origin) || %{worker: "Apiary.Setup"}
             ) do
          {:ok, _signed_up} = done -> done
          {:error, :instance_claimed} -> {:error, :already_set_up}
          {:error, _reason} = error -> error
        end
    end
  end

  @doc false
  # The first sign-up's step, inside its transaction and after the instance's
  # first-sign-up lock (`Apiary.Organisations.sign_up_user/3`): holds the row, compares
  # `code` with the stored one when one is given (the link's set-up; the release command
  # gives none), and marks the code used. With a preset (`preset!/0`), `code` is compared
  # with the preset instead, and the preset is written to `used_setup_code_sha256`, by
  # the release command's sign-up too. `{:ok, way}`, the way the instance was set up, for
  # the entry of its organisation (`details.setup_code`): `"link"` with the stored code,
  # `"preset"` with the preset code, `"command"` without a code. Or
  # `{:error, :invalid_code}`.
  @spec use_code(Ecto.Repo.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :invalid_code}
  def use_code(repo, code) do
    {stored, used} = lock_row(repo)
    preset = preset!()

    cond do
      is_nil(code) ->
        mark_used(repo, preset, "command")

      is_nil(preset) and is_binary(stored) and same_code?(stored, code) ->
        mark_used(repo, nil, "link")

      is_binary(preset) and preset_code?(preset, used, code) ->
        mark_used(repo, preset, "preset")

      true ->
        {:error, :invalid_code}
    end
  end

  defp mark_used(repo, nil, way) do
    repo.query!(
      "UPDATE instance_settings SET setup_code = NULL, set_up_at = $1 WHERE id",
      [DateTime.utc_now()]
    )

    {:ok, way}
  end

  # Not in the query log, whose debug lines print a query's parameters.
  defp mark_used(repo, preset, way) do
    repo.query!(
      "UPDATE instance_settings SET setup_code = NULL, set_up_at = $1, " <>
        "used_setup_code_sha256 = $2 WHERE id",
      [DateTime.utc_now(), preset],
      log: false
    )

    {:ok, way}
  end

  @doc """
  claim/3 sets up an instance from a shell, for `Apiary.Release.grant_instance_admin/2`:
  the instance's first sign-up with `email` and `organisation_name`, by the instance, from
  `origin`, which marks any stored code used, and the preset with one (`preset!/0`), then
  the account's log-in link, sent as the sign-up page sends it. `{:ok, user, :sent}`, or `{:ok, user, :not_sent}` when the mail
  did not go out; `{:error, :instance_claimed}` once the instance has its organisation, a
  set-up that came first included; or `{:error, changeset}`, the sign-up form's, for an
  address or a name it refuses. A refusal with the instance claimed by then is
  `{:error, :instance_claimed}` too: the account a set-up a moment before created makes
  the address taken before this sign-up's transaction starts, which would otherwise
  answer it.
  """
  @spec claim(String.t(), String.t(), map) ::
          {:ok, %User{}, :sent | :not_sent}
          | {:error, :instance_claimed | Ecto.Changeset.t()}
  def claim(email, organisation_name, origin) do
    case Organisations.sign_up_user(%{email: email, organisation_name: organisation_name}, nil,
           first_only: true,
           actor: :instance,
           origin: origin
         ) do
      {:ok, %{user: user}} ->
        {:ok, user, send_log_in_link(user)}

      {:error, %Ecto.Changeset{}} = error ->
        if set_up?(), do: {:error, :instance_claimed}, else: error

      {:error, :instance_claimed} = error ->
        error
    end
  end

  @doc """
  error_messages/1 is each error of `changeset` as `{field, text}`, in its order, the
  text with the placeholders its message names filled in from the error's options: a
  string as it is, a number or an atom as text, anything else inspected. An option the
  message does not name is left out, so a list or a tuple among them is never a crash.
  """
  @spec error_messages(Ecto.Changeset.t()) :: [{atom, String.t()}]
  def error_messages(%Ecto.Changeset{errors: errors}) do
    for {field, {message, opts}} <- errors, do: {field, error_text(message, opts)}
  end

  defp error_text(message, opts) do
    Regex.replace(~r/%{(\w+)}/, message, fn placeholder, key ->
      case Enum.find(opts, fn {name, _value} -> Atom.to_string(name) == key end) do
        {_name, value} -> option_text(value)
        nil -> placeholder
      end
    end)
  end

  defp option_text(value) when is_binary(value), do: value
  defp option_text(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp option_text(value), do: inspect(value)

  @doc """
  message/2 is what a claim says once it is made: the account's id, never its address or
  its link; with `:not_sent`, to ask for a link at `/users/log-in` once mail works.
  """
  @spec message(%User{}, :sent | :not_sent) :: String.t()
  def message(%User{id: id}, :sent),
    do: "The account #{id} is the instance's first admin; its log-in link is on its way."

  def message(%User{id: id}, :not_sent),
    do:
      "The account #{id} is the instance's first admin, but its log-in link " <>
        "could not be sent. Check the mail settings, then ask for a link at " <>
        "#{public_url()}/users/log-in."

  @doc """
  public_url/0 is the instance's address for a link: the endpoint's, when it runs, else
  the one its configuration gives, as `bin/apiary eval` and the boot before the endpoint
  have no endpoint running.
  """
  @spec public_url() :: String.t()
  def public_url do
    if :persistent_term.get({Phoenix.Endpoint, ApiaryWeb.Endpoint}, nil),
      do: ApiaryWeb.Endpoint.url(),
      else: configured_url(Application.get_env(:apiary, ApiaryWeb.Endpoint, []))
  end

  @doc false
  # The address the endpoint's configuration gives, built as Phoenix builds the endpoint's
  # own (`Phoenix.Endpoint.url/0`), which is not there before the endpoint starts: the
  # scheme and port of `https:`, else of `http:`, else http and 80, each replaced by the
  # one `url:` names; a scheme's own port left out.
  @spec configured_url(keyword) :: String.t()
  def configured_url(config) do
    url = config[:url] || []

    {scheme, port} =
      cond do
        https = config[:https] -> {"https", https[:port] || 443}
        http = config[:http] -> {"http", http[:port] || 80}
        true -> {"http", 80}
      end

    URI.to_string(%URI{
      scheme: url[:scheme] || scheme,
      host: url[:host] || "localhost",
      port: port_integer(url[:port] || port)
    })
  end

  defp port_integer(port) when is_binary(port), do: String.to_integer(port)
  defp port_integer(port), do: port

  # The log-in link, sent as the sign-up page sends it. A failure says nothing of why: the
  # relay's reason may quote the message, which holds the address and the link.
  defp send_log_in_link(user) do
    case Apiary.Accounts.deliver_login_instructions(
           user,
           &"#{public_url()}/users/log-in/#{&1}"
         ) do
      {:ok, _email} -> :sent
      _error -> :not_sent
    end
  rescue
    _exception -> :not_sent
  catch
    _kind, _reason -> :not_sent
  end
end
