defmodule Apiary.FirstAdmin do
  @moduledoc """
  The instance's first admin, claimed at its first start from two settings, so an install
  needs no command and no web sign-up can come first; and the claim itself, which the
  release command `Apiary.Release.grant_instance_admin/2` runs too.

  **The settings.** `FIRST_ADMIN_EMAIL`, the first admin's address, and
  `FIRST_ORGANISATION_NAME`, the name of the instance's organisation, read by
  `config/runtime.exs` and trimmed; a value empty after trimming is an unset one. Both are
  optional: both empty leaves the first sign-up to the web, as without them.

  **At boot.** `start_link/0` is the child of the application's supervisor after
  `Apiary.KeyCheck` and the edition's processes, and just before `ApiaryWeb.Endpoint`, so
  the instance serves nothing before the claim. Both empty, it stops there, without a
  query. Otherwise it asks whether the instance has its organisation
  (`c:Apiary.Edition.instance_organisation_id/0`); when it has, a restored one included,
  the step ends there: it checks neither value, creates and grants nothing, sends no mail
  and writes no line, so the claim is the first start's alone. On an instance nobody has
  signed up to, with both set, it claims the instance (`claim/3`); with one set and the
  other empty, or a value the sign-up refuses, it stops the boot with a message in the log
  that names the variable and never the value. Of two boots at once, one claims, and the
  other's claim answers `{:error, :instance_claimed}`; it moves on.

  **The claim.** `claim/3` is the instance's first sign-up,
  `Apiary.Organisations.sign_up_user/3` with `first_only: true` and `actor: :instance`, so
  the edition's part of a first sign-up applies as it does on the web: it creates the
  instance's organisation, its workspace Main and the account as its owner, then sends the
  account its log-in link. Should the mail not go out, the instance is claimed all the
  same, and the line written says to ask for a link at `/users/log-in`, without the
  address or the link.
  """

  require Logger

  alias Apiary.Accounts.User
  alias Apiary.Organisations

  @origin %{worker: "Apiary.FirstAdmin"}

  # The sign-up's refusal when every slug picked for the organisation was taken a moment
  # before (`Apiary.Organisations.sign_up_user/3`), on its form's `email`.
  @slug_taken "could not be signed up just now; please try again"

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

  @doc """
  Runs the step at boot: `:ignore` once it has claimed the instance or had nothing to do,
  so nothing stays in the supervision tree; otherwise logs the message and exits, which
  takes the boot down.
  """
  @spec start_link() :: :ignore
  def start_link do
    case run() do
      :ok ->
        :ignore

      {:error, message} ->
        Logger.error(message)
        exit(:first_admin_refused)
    end
  end

  @doc """
  run/0 claims an instance nobody has signed up to with the settings, when both are set:
  `:ok`, or `{:error, message}` for a boot it stops. See the module's documentation.
  """
  @spec run() :: :ok | {:error, String.t()}
  def run do
    email = setting(:first_admin_email_setting)
    name = setting(:first_organisation_name_setting)

    cond do
      is_nil(email) and is_nil(name) -> :ok
      Apiary.Edition.instance_organisation_id() -> :ok
      is_nil(name) -> {:error, half_set("FIRST_ORGANISATION_NAME", "FIRST_ADMIN_EMAIL")}
      is_nil(email) -> {:error, half_set("FIRST_ADMIN_EMAIL", "FIRST_ORGANISATION_NAME")}
      true -> claim_at_boot(email, name)
    end
  end

  defp claim_at_boot(email, name) do
    case claim(email, name, @origin) do
      {:ok, user, :sent} ->
        Logger.info(message(user, :sent))
        :ok

      {:ok, user, :not_sent} ->
        Logger.warning(message(user, :not_sent))
        :ok

      # Another boot claimed it a moment before: the instance has its admin.
      {:error, :instance_claimed} ->
        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, refusal(changeset)}
    end
  end

  @doc """
  claim/3 claims an instance nobody has signed up to: the instance's first sign-up with
  `email` and `organisation_name`, by the instance, from `origin`, then the account's
  log-in link, sent as the sign-up page sends it. `{:ok, user, :sent}`, or
  `{:ok, user, :not_sent}` when the mail did not go out; `{:error, :instance_claimed}`
  once the instance has its organisation, a sign-up that came first included; or
  `{:error, changeset}`, the sign-up form's, for an address or a name it refuses. A
  refusal with the instance claimed by then is `{:error, :instance_claimed}` too: the
  account a sign-up a moment before created makes the address taken before this sign-up's
  transaction starts, which would otherwise answer it.
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
        if Apiary.Edition.instance_organisation_id(), do: {:error, :instance_claimed}, else: error

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
  public_url/0 is the instance's address for a link in mail: the endpoint's, when it runs,
  else the one its configuration gives, as `bin/apiary eval` and the boot before the
  endpoint have no endpoint running.
  """
  @spec public_url() :: String.t()
  def public_url do
    if :persistent_term.get({Phoenix.Endpoint, ApiaryWeb.Endpoint}, nil) do
      ApiaryWeb.Endpoint.url()
    else
      url = Application.get_env(:apiary, ApiaryWeb.Endpoint, [])[:url] || []

      URI.to_string(%URI{
        scheme: url[:scheme] || "https",
        host: url[:host] || "localhost",
        port: url[:port]
      })
    end
  end

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

  # A setting as config/runtime.exs left it, trimmed; nil when unset or empty.
  defp setting(key) do
    case Application.get_env(:apiary, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _unset ->
        nil
    end
  end

  defp half_set(missing, set) do
    """
    environment variable #{missing} is empty, and #{set} is set. \
    Set both to claim this instance at its first start, or neither.\
    """
  end

  @doc """
  refusal/1 is what the log says when the sign-up refuses the settings: a line for each
  variable whose value it refused, with the sign-up's own messages and never the value, so
  the address stays out of the log. An error on a field of an edition's, which neither
  variable holds, names both.
  """
  @spec refusal(Ecto.Changeset.t()) :: String.t()
  def refusal(changeset) do
    changeset
    |> error_messages()
    |> Enum.map(fn {field, text} -> {variable(field, text), text} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(fn {variable, _texts} -> variable_order(variable) end)
    |> Enum.map_join("\n", fn
      {{:other, field}, texts} ->
        "environment variables FIRST_ADMIN_EMAIL and FIRST_ORGANISATION_NAME were refused: " <>
          "#{field} #{Enum.join(texts, "; ")}."

      {variable, texts} ->
        "environment variable #{variable} is not valid: #{Enum.join(texts, "; ")}."
    end)
  end

  # The variable an error of the sign-up form comes from. The form puts an error of the
  # organisation's name or slug on `organisation_name`, and the refusal of a slug taken
  # by a sign-up at the same moment on `email`, where the sign-up page shows it; that one
  # is the organisation's name's too.
  defp variable(:organisation_name, _text), do: "FIRST_ORGANISATION_NAME"
  defp variable(:email, @slug_taken), do: "FIRST_ORGANISATION_NAME"
  defp variable(:email, _text), do: "FIRST_ADMIN_EMAIL"
  defp variable(field, _text), do: {:other, field}

  defp variable_order("FIRST_ADMIN_EMAIL"), do: 0
  defp variable_order("FIRST_ORGANISATION_NAME"), do: 1
  defp variable_order({:other, field}), do: {2, field}
end
