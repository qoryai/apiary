defmodule Apiary.Setup do
  @moduledoc """
  The instance's set-up link, `/setup/<code>`: the one way to make the first admin of an
  instance from a browser. Its page (`ApiaryWeb.SetupLive`) asks for an email address, a
  password and the organisation's name, and makes the instance's first account, its
  organisation and the workspace Main. Until it is used nobody can sign up
  (`Apiary.Organisations.sign_up_offer/1` answers `:not_set_up`).

  **The code.** 32 random bytes (`:crypto.strong_rand_bytes/1`) in base64url without
  padding, 43 characters. It is stored as it is in the instance's own row of
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

  That line is the only place the code is written. Once the instance is set up, a start
  finds, makes and logs nothing. Off in test (`config :apiary, Apiary.Setup, enabled:
  false`), where the tests call `boot/0` themselves.

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

  # The instance's own row, made when nothing has made it yet, with the columns' defaults.
  @ensure_row """
  INSERT INTO instance_settings (id, updated_at) VALUES (true, $1)
  ON CONFLICT (id) DO NOTHING
  """

  @lock_row "SELECT setup_code FROM instance_settings WHERE id FOR UPDATE"

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
  by `code!/0`; once it is set up it does nothing. `:ok`.
  """
  @spec boot() :: :ok
  def boot do
    case find_or_create() do
      {:ok, code} -> Logger.info(log_line(code))
      :set_up -> :ok
    end

    :ok
  end

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
  code!/0 is the set-up code, found or made: the stored one, or else a new one, stored
  before it is returned, all under the row's lock. The same code until it is used.
  Raises once the instance is set up, when there is no code to give.
  """
  @spec code!() :: String.t()
  def code! do
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
          stored = lock_row(Repo)

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

  defp lock_row(repo) do
    repo.query!(@ensure_row, [DateTime.utc_now()])
    %{rows: [[stored]]} = repo.query!(@lock_row)
    stored
  end

  @doc """
  valid_code?/1 says whether `code` is the stored, unused set-up code, compared in
  constant time; read without a lock, for the set-up page to decide what it shows.
  `set_up/3` checks again under the lock.
  """
  @spec valid_code?(term) :: boolean
  def valid_code?(code) when is_binary(code) do
    case Repo.query!("SELECT setup_code FROM instance_settings WHERE id") do
      %{rows: [[stored]]} when is_binary(stored) -> same_code?(stored, code)
      _none -> false
    end
  end

  def valid_code?(_code), do: false

  # The one comparison of a code with the stored one, in constant time, so the time it
  # takes tells nothing of how much of the code was right.
  defp same_code?(stored, code), do: Plug.Crypto.secure_compare(stored, code)

  @doc """
  set_up/3 sets the instance up with `code`: the instance's first sign-up,
  `Apiary.Organisations.sign_up_user/3` with `first_only: true` and `actor: :instance`,
  in one transaction that also checks the code under the row's lock and marks it used.
  `attrs` are the sign-up form's: `email`, `organisation_name`, `password` and
  `password_confirmation`. It creates the instance's organisation, its workspace Main
  and the account as its owner, and the edition's part of a first sign-up applies
  (`:first_sign_up`).

  Answers `{:ok, map}` as the sign-up does; `{:error, :already_set_up}` once the instance
  is set up, a set-up a moment before included; `{:error, :invalid_code}` for a code that
  is not the stored one; or `{:error, changeset}`, the sign-up form's.

  `password: :required` asks for a password, as the set-up page does; by default it is
  required while the instance sends no email (`Apiary.Mail.configured?/0`), as a
  person's sign-up's is, and optional once it does; a password given is kept either way. `origin:` is where the set-up comes from, for its entry
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
  # gives none), and marks the code used. `{:ok, nil}`, or `{:error, :invalid_code}`.
  @spec use_code(Ecto.Repo.t(), String.t() | nil) :: {:ok, nil} | {:error, :invalid_code}
  def use_code(repo, code) do
    stored = lock_row(repo)

    if is_nil(code) or (is_binary(stored) and same_code?(stored, code)) do
      repo.query!(
        "UPDATE instance_settings SET setup_code = NULL, set_up_at = $1 WHERE id",
        [DateTime.utc_now()]
      )

      {:ok, nil}
    else
      {:error, :invalid_code}
    end
  end

  @doc """
  claim/3 sets up an instance from a shell, for `Apiary.Release.grant_instance_admin/2`:
  the instance's first sign-up with `email` and `organisation_name`, by the instance, from
  `origin`, which marks any stored code used, then the account's log-in link, sent as the
  sign-up page sends it. `{:ok, user, :sent}`, or `{:ok, user, :not_sent}` when the mail
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
