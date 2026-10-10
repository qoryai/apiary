defmodule Apiary.Mail do
  @moduledoc """
  Whether this instance sends email, and where its mail settings come from. Every email
  goes through `Apiary.Accounts.UserNotifier`, which asks here first, and sends nothing
  when no mail is set.

  **The source** (`source/0`):

  | Source | Meaning |
  |---|---|
  | `:env` | The application's environment sets the mailer's adapter. In production that is `SMTP_RELAY` and the variables beside it, read by `config/runtime.exs`; in development the Swoosh local adapter, and in the tests the Swoosh test adapter. |
  | `:settings` | Not set by anything yet; only `put_test_source/1` gives it. |
  | `:none` | No mail is set: in production, `SMTP_RELAY` is not set, or empty. |

  `configured?/0` is true for `:env` and `:settings`. A production release without
  `SMTP_RELAY` starts all the same, and `boot/0` says once, at `info`, that no mail is
  set.

  **The test seam.** `put_test_source/1` sets the source for the calling process and the
  processes it starts that keep it among their `$callers` (a `Task`, a LiveView under
  test), and for no other process, so tests that set different sources run at once
  (`async: true`). Under it, an email that is sent still goes through the application's
  own adapter, the Swoosh test adapter in the tests.
  """

  require Logger

  @typedoc "Where the mail settings come from."
  @type source :: :env | :settings | :none

  @test_source {__MODULE__, :test_source}

  @no_mail "No mail is set: invitations and password links are copied by hand. Set mail in Instance settings › Mail."

  @doc "Whether this instance sends email: its source is not `:none`."
  @spec configured?() :: boolean
  def configured?, do: source() != :none

  @doc "Where this instance's mail settings come from; see the module's documentation."
  @spec source() :: source
  def source do
    case test_source() do
      nil -> env_source(Application.get_env(:apiary, Apiary.Mailer, []))
      source -> source
    end
  end

  @doc """
  The configuration to send an email with, for `Apiary.Mailer.deliver/2`, or `nil` when no
  mail is set: the application's environment for `Apiary.Mailer`, whose adapter is set.
  """
  @spec mailer_config() :: keyword | nil
  def mailer_config do
    case source() do
      :none -> nil
      _set -> Application.get_env(:apiary, Apiary.Mailer, [])
    end
  end

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
  Says once, at boot, at `info`, that no mail is set, when none is. The application calls
  it before it starts its processes.
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
