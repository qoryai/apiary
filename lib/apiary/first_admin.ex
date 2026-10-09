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
  the instance serves nothing before the claim. On an instance that has its organisation
  (`c:Apiary.Edition.instance_organisation_id/0`), a restored one included, it does
  nothing, whatever the settings say: the claim is the first start's alone. On an
  instance nobody has signed up to, with both set, it claims the instance (`claim/3`);
  with one set and the other empty, or a value the sign-up refuses, it stops the boot with
  a message in the log that names the variable and never the value. Of two boots at once,
  one claims, and the other's sign-up answers `{:error, :instance_claimed}`; it moves on.

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
  `{:error, changeset}`, the sign-up form's, for an address or a name it refuses.
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
      {:ok, %{user: user}} -> {:ok, user, send_log_in_link(user)}
      {:error, _reason} = error -> error
    end
  end

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

  # A line for each variable whose value the sign-up refused, with the sign-up's own
  # messages and never the value: the address stays out of the log.
  defp refusal(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.sort_by(fn {field, _messages} -> field != :email end)
    |> Enum.map_join("\n", fn {field, messages} ->
      "environment variable #{variable(field)} is not valid: #{Enum.join(messages, "; ")}."
    end)
  end

  defp variable(:organisation_name), do: "FIRST_ORGANISATION_NAME"
  defp variable(_email), do: "FIRST_ADMIN_EMAIL"
end
