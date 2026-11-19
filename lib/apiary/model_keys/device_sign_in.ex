defmodule Apiary.ModelKeys.DeviceSignIn do
  @moduledoc """
  One device sign-in of a model key, for a form (the LiveView helper
  ApiaryWeb.ModelKeyDevice): Qory Apiary requests a code from the provider, the person
  enters the code on the provider's page, and Qory Apiary polls until the person approves,
  exchanges the grant for the tokens and keeps them as a `t:Apiary.ModelKeys.Login.parsed/0`.
  The calls are `Apiary.ModelKeys.LoginDevice`; their addresses and the client id come from
  `oauth_device` and `oauth_refresh` of the provider's catalogue entry alone.

  The sign-in is a process that belongs to the form's process (the `owner`): it monitors
  the owner and ends when the owner ends, and when `stop/1` says so. It polls every
  `interval` seconds the provider sent, at least 5 (`Apiary.ModelKeys.LoginDevice`), until the code's `expires_at` or 30 minutes after
  the start, whichever is first, and makes no call after it ends. A poll that gets a 429
  or a 5xx waits for the longer of the interval and the `Retry-After` header (at most 60
  seconds); a 429 does not count as a failure, and five failed polls in a
  row (a 5xx or any other failure) end the sign-in. It sends the owner
  `{:device_sign_in, ref, event}`:

    * `{:code, %{user_code:, verification_url:, expires_at:}}`, once the provider has given
      a code: the only part of the sign-in the page shows;
    * `:signed_in`, once the tokens are in the process;
    * `{:ended, :expired}`, when the code stopped working before the person approved;
    * `{:ended, :off}`, when the provider has no device code sign-in for the account (a
      404 for the code; unconfirmed until a real run);
    * `{:ended, :failed, cause}`, for any other failure, where `cause` is the HTTP status
      of the response that failed it, `:unknown` for a failure with no status (a network
      error, a timeout, a response that is no grant or no tokens, an address the catalogue
      entry has wrong), or `:no_account` for a response with no account id.

  `login/1` returns the tokens to the owner alone, as `t:Apiary.ModelKeys.Login.parsed/0`;
  the owner passes them to `Apiary.Connections` when the person saves. The process keeps
  them until it ends, so `login/1` can be read again. No token, code, device id or
  response is in a message, a log line, an audit entry or a telemetry event, and
  `format_status/1` hides the state from a crash report. A crash in a poll or in the
  exchange ends the sign-in as failed, with no state or argument written out.

  A catalogue entry without `oauth_device` has no device sign-in: `start/2` returns
  `{:error, :device_flow_unavailable}`, and `available?/1` is false.
  """

  use GenServer, restart: :temporary

  alias Apiary.Kinds.{Provider, Providers}
  alias Apiary.ModelKeys.{Login, LoginDevice}

  @supervisor __MODULE__.Supervisor
  # The most failed calls in a row that a sign-in goes on after, and the longest a code is
  # polled, whatever its `expires_at`.
  @failures_max 5
  @poll_limit_seconds 30 * 60
  @test_seam Application.compile_env(:apiary, [__MODULE__, :test_seam], false)

  @typedoc "What a catalogue entry gives a device sign-in."
  @type description :: %{
          device: LoginDevice.device(),
          token_url: String.t(),
          client_id: String.t(),
          account_claim: String.t() | nil
        }

  @doc "The name of the supervisor of the sign-ins, for the application's children."
  @spec supervisor() :: atom
  def supervisor, do: @supervisor

  @doc """
  The device sign-in of the keys of the provider `kind`, a catalogue name: `{:ok, description}`
  from the API of the entry that has both `oauth_refresh` and `oauth_device`, else `:error`.
  """
  @spec description(term) :: {:ok, description} | :error
  def description(kind) when is_binary(kind) do
    with {:ok, %Provider{apis: apis}} <- Providers.fetch(kind),
         %{"oauth_refresh" => %{"url" => token_url, "client_id" => client_id}} = api <-
           Enum.find(apis, &is_map(&1["oauth_refresh"])),
         %{} = device <- device(kind, api["oauth_device"]) do
      {:ok,
       %{
         device: device,
         token_url: token_url,
         client_id: client_id,
         account_claim: get_in(api, ["auth", "account_claim"])
       }}
    else
      _none -> :error
    end
  end

  def description(_kind), do: :error

  @doc "Whether the keys of the provider `kind` have a device sign-in."
  @spec available?(term) :: boolean
  def available?(kind), do: match?({:ok, _description}, description(kind))

  @doc """
  Starts the sign-in of a key of the provider `kind` for the calling process, which then
  gets the messages with `ref`: `{:ok, pid}`, or `{:error, :device_flow_unavailable}` for a
  provider without a device sign-in.
  """
  @spec start(String.t(), reference) :: {:ok, pid} | {:error, :device_flow_unavailable}
  def start(kind, ref) when is_reference(ref) do
    case description(kind) do
      {:ok, description} ->
        # The process runs under the sign-in supervisor, which gives it no `$callers`; the
        # owner's let a test's `Req.Test` stub and seam reach the calls.
        args = %{
          owner: self(),
          ref: ref,
          description: description,
          callers: [self() | Process.get(:"$callers", [])]
        }

        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, args}) do
          {:ok, pid} -> {:ok, pid}
          _failed -> {:error, :device_flow_unavailable}
        end

      :error ->
        {:error, :device_flow_unavailable}
    end
  end

  @doc "Stops the sign-in `pid` and forgets its code and tokens. Always `:ok`."
  @spec stop(pid | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    GenServer.cast(pid, :stop)
  end

  @doc """
  The tokens of the finished sign-in `pid`, for its owner alone: `{:ok, login}`, as
  `Apiary.ModelKeys.Login.from_tokens/3` makes it, or `:error` for a sign-in that is not
  finished, that is gone, or whose owner is another process. The sign-in keeps the tokens
  until it ends, so the owner can read them again.
  """
  @spec login(pid | nil) :: {:ok, Login.parsed()} | :error
  def login(nil), do: :error

  def login(pid) when is_pid(pid) do
    GenServer.call(pid, :login, 5_000)
  catch
    :exit, _reason -> :error
  end

  @doc false
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  ## The process

  @impl true
  def init(%{owner: owner, ref: ref, description: description, callers: callers}) do
    Process.put(:"$callers", callers)
    Process.monitor(owner)

    {:ok,
     %{
       owner: owner,
       ref: ref,
       description: description,
       code: nil,
       interval_ms: nil,
       expires_at: nil,
       limit: System.monotonic_time(:second) + @poll_limit_seconds,
       failures: 0,
       login: nil
     }, {:continue, :request_code}}
  end

  @impl true
  def handle_continue(:request_code, state), do: guarded(state, &request_code/1)

  @impl true
  def handle_info(:poll, %{code: code} = state) when is_map(code), do: guarded(state, &poll/1)

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:login, {owner, _tag}, %{owner: owner, login: %{} = login} = state),
    do: {:reply, {:ok, login}, state}

  def handle_call(:login, _from, state), do: {:reply, :error, state}

  @impl true
  def handle_cast(:stop, state), do: {:stop, :normal, state}

  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)

  # Any raise or exit in a step ends the sign-in as failed. The exception is not kept, so
  # no crash report carries the grant that the step had as an argument.
  defp guarded(state, step) do
    step.(state)
  rescue
    _exception -> ended(state, :failed, :unknown)
  catch
    _kind, _reason -> ended(state, :failed, :unknown)
  end

  defp request_code(state) do
    %{device: device, client_id: client_id} = state.description

    case LoginDevice.request_code(device, client_id) do
      {:ok, code} ->
        send_owner(state, {:code, shown(code, device)})
        state = %{state | code: code, expires_at: code.expires_at, interval_ms: ms(code)}
        schedule(state)
        {:noreply, state}

      :off ->
        ended(state, :off)

      failure ->
        ended(state, :failed, cause(failure))
    end
  end

  defp poll(state) do
    if expired?(state) do
      ended(state, :expired)
    else
      case LoginDevice.poll(state.description.device, state.code) do
        :pending ->
          schedule(state)
          {:noreply, %{state | failures: 0}}

        {:ok, grant} ->
          exchange(state, grant)

        {:error, "http_429", retry_after} ->
          # Told to slow down: not a failure of the sign-in.
          schedule(state, delay(state, retry_after))
          {:noreply, state}

        {:error, _word, retry_after} = failure ->
          failed_call(state, failure, delay(state, retry_after))

        failure ->
          failed_call(state, failure, state.interval_ms)
      end
    end
  end

  defp exchange(state, grant) do
    %{description: description} = state

    with true <- Process.alive?(state.owner),
         {:ok, response} <-
           LoginDevice.exchange(
             description.token_url,
             description.device,
             description.client_id,
             grant
           ),
         {:ok, login} <- Login.from_tokens(response, description.account_claim) do
      send_owner(state, :signed_in)
      {:noreply, %{state | login: login, code: nil}}
    else
      false -> {:stop, :normal, state}
      {:error, :no_account} -> ended(state, :failed, :no_account)
      {:error, :invalid} -> ended(state, :failed, :unknown)
      failure -> ended(state, :failed, cause(failure))
    end
  end

  # A call that failed: the sign-in goes on after a few in a row, as a network that
  # failed once may be back at the next poll.
  defp failed_call(%{failures: failures} = state, failure, _delay)
       when failures + 1 >= @failures_max,
       do: ended(state, :failed, cause(failure))

  defp failed_call(state, _failure, delay) do
    schedule(state, delay)
    {:noreply, %{state | failures: state.failures + 1}}
  end

  # The wait after a response with a `Retry-After` of `seconds`: the longer of that and the
  # interval, so a short `Retry-After` never makes the polls faster than the interval.
  defp delay(state, seconds) when is_integer(seconds),
    do: max(state.interval_ms, seconds * 1000)

  defp delay(state, _none), do: state.interval_ms

  # The HTTP status of a failure's word, `:unknown` for a failure with no status.
  defp cause({:error, "http_" <> status, _retry_after}), do: cause({:error, "http_" <> status})

  defp cause({:error, "http_" <> status}) do
    case Integer.parse(status) do
      {status, ""} -> status
      _other -> :unknown
    end
  end

  defp cause(_failure), do: :unknown

  defp ended(state, reason) do
    send_owner(state, {:ended, reason})
    {:stop, :normal, state}
  end

  defp ended(state, :failed, cause) do
    send_owner(state, {:ended, :failed, cause})
    {:stop, :normal, state}
  end

  defp send_owner(%{owner: owner, ref: ref}, event),
    do: send(owner, {:device_sign_in, ref, event})

  defp schedule(state, delay \\ nil),
    do: Process.send_after(self(), :poll, delay || state.interval_ms)

  defp expired?(state) do
    DateTime.compare(DateTime.utc_now(), state.expires_at) != :lt or
      System.monotonic_time(:second) >= state.limit
  end

  # The milliseconds between two polls: the seconds the provider sent. A test build may set
  # `interval_ms`; any other build ignores it.
  if @test_seam do
    defp ms(%{interval: seconds}) do
      Application.get_env(:apiary, __MODULE__, [])[:interval_ms] || seconds * 1000
    end
  else
    defp ms(%{interval: seconds}), do: seconds * 1000
  end

  # What the page shows of a code: the code, the page it is entered on and until when it
  # works. The page's address is the catalogue's `verification_url`.
  defp shown(code, device),
    do: %{
      user_code: code.user_code,
      verification_url: device["verification_url"],
      expires_at: code.expires_at
    }

  ## The seam of the tests

  if @test_seam do
    @test_device {__MODULE__, :test_device}
    @stubbed {__MODULE__, :stubbed}

    # put_test_device/2 gives the keys of the provider `kind` the `oauth_device` `device`
    # in this process and in the processes it starts, such as a LiveView of a test, until
    # the process ends: the vendored description has none yet. `nil` takes it away.
    @doc false
    @spec put_test_device(String.t(), map | nil) :: :ok
    def put_test_device(kind, device) when is_binary(kind) do
      unless :persistent_term.get(@stubbed, false), do: :persistent_term.put(@stubbed, true)
      Process.put({@test_device, kind}, device)
      :ok
    end

    defp device(kind, catalogued) do
      stubbed =
        if :persistent_term.get(@stubbed, false) do
          Enum.find_value([self() | Process.get(:"$callers", [])], fn
            pid when pid == self() -> Process.get({@test_device, kind})
            pid -> caller_device(pid, kind)
          end)
        end

      stubbed || catalogued
    end

    defp caller_device(pid, kind) when is_pid(pid) do
      case Process.info(pid, {:dictionary, {@test_device, kind}}) do
        {{:dictionary, {@test_device, ^kind}}, %{} = device} -> device
        _unset_or_gone -> nil
      end
    end

    defp caller_device(_name, _kind), do: nil
  else
    defp device(_kind, device), do: device
  end
end
