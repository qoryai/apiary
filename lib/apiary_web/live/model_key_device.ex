defmodule ApiaryWeb.ModelKeyDevice do
  # The device sign-in of a key's form (`Apiary.ModelKeys.DeviceSignIn`) for a LiveView:
  # Add key, Edit key, New model provider, the set-up's Model step, and a secret's Add
  # value and Change value, in the core and in the Pro Secrets page. The LiveView calls
  # `attach/2` in its mount and shows `ApiaryWeb.ModelKeyComponents.sign_in_with_chatgpt/1`
  # with the `device` assign; the hooks here read the events `device_sign_in` (the button)
  # and `device_cancel` (Cancel next to the waiting line) and the messages of the sign-in.
  #
  # The `device` assign has the state and what the page shows of the sign-in (the code, the
  # page's address, until when the code works and, for a failed one, the cause), and the
  # sign-in's process, which holds the tokens. The tokens are never in an assign: `login/1`
  # reads them for a save. The sign-in's process ends when the LiveView ends, so a person
  # who leaves the form stops the polling.
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Apiary.ModelKeys.DeviceSignIn

  @starts [:idle, :expired, :off, :failed]

  @typedoc "The sign-in of the form: its state and what the page shows."
  @type t :: %{
          kind: String.t(),
          state: :idle | :starting | :code | :signed_in | :expired | :off | :failed,
          pid: pid | nil,
          ref: reference | nil,
          key: String.t() | nil,
          user_code: String.t() | nil,
          verification_url: String.t() | nil,
          expires_at: DateTime.t() | nil,
          cause: pos_integer | :unknown | nil
        }

  @doc """
  Hooks the events and the messages of a device sign-in into the LiveView, and assigns
  `device` for the keys of the provider `kind` (`for_provider/2`). With `signed_in:`, a
  function of the socket, the LiveView stores the sign-in as soon as the person has signed
  in (a button in a list's row starts such a sign-in, with no form to save).
  """
  @spec attach(Phoenix.LiveView.Socket.t(), String.t() | nil, keyword) ::
          Phoenix.LiveView.Socket.t()
  def attach(socket, kind \\ nil, opts \\ []) do
    signed_in = Keyword.get(opts, :signed_in, & &1)

    socket
    |> attach_hook(:device_sign_in_event, :handle_event, &event/3)
    |> attach_hook(:device_sign_in_info, :handle_info, &info(&1, &2, signed_in))
    |> assign(:device, nil)
    |> for_provider(kind)
  end

  @doc """
  Makes `device` the sign-in of a key of the provider `kind`, a catalogue name: an idle one
  for a provider with a device sign-in, nil for any other. A sign-in that was going on
  stops, unless `kind` is the one it is for.
  """
  @spec for_provider(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  def for_provider(socket, kind) do
    case socket.assigns[:device] do
      %{kind: ^kind} ->
        socket

      current ->
        stop(current)
        assign(socket, :device, idle(kind))
    end
  end

  @doc "Stops the sign-in that is going on and makes `device` idle again, as it was."
  @spec reset(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset(socket) do
    case socket.assigns[:device] do
      %{kind: kind} = current ->
        stop(current)
        assign(socket, :device, idle(kind))

      nil ->
        socket
    end
  end

  @doc """
  The sign-in a form saves: `{:ok, login}` once the person has signed in
  (`t:Apiary.ModelKeys.Login.parsed/0`), else `:error`.
  """
  @spec login(Phoenix.LiveView.Socket.t()) :: {:ok, Apiary.ModelKeys.Login.parsed()} | :error
  def login(socket) do
    case socket.assigns[:device] do
      %{state: :signed_in, pid: pid} -> DeviceSignIn.login(pid)
      _none -> :error
    end
  end

  @doc """
  Ends the sign-in of a LiveView that could not store it, as one that failed: the page
  shows the fix of a failed sign-in and the button.
  """
  @spec fail(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def fail(socket) do
    case socket.assigns[:device] do
      %{kind: kind, key: key} = device ->
        stop(device)
        assign(socket, :device, %{idle(kind) | state: :failed, key: key, cause: nil})

      nil ->
        socket
    end
  end

  @doc """
  The value a form saves for a key: for `login?`, a provider whose keys are logins, the
  sign-in once the person has made it, else "" (nothing); for any other provider, `key`,
  the text of the Key field.
  """
  @spec value(Phoenix.LiveView.Socket.t(), boolean, String.t() | nil) ::
          Apiary.ModelKeys.Login.parsed() | String.t()
  def value(socket, true, _key) do
    case login(socket) do
      {:ok, login} -> login
      :error -> ""
    end
  end

  def value(_socket, false, key), do: key || ""

  @doc """
  `params` of a secret's value form with the sign-in of a provider whose keys are logins as
  its `"value"`: the form sends no value for it, so a value it sent is dropped. The
  provider is the LiveView's `provider` assign; any other `params` are returned as they are.
  """
  @spec put_login(map, Phoenix.LiveView.Socket.t()) :: map
  def put_login(
        params,
        %{assigns: %{provider: %Apiary.Connections.Connection{} = provider}} = socket
      ) do
    if Apiary.ModelKeys.Login.provider?(provider) do
      case login(socket) do
        {:ok, login} -> Map.put(params, "value", login)
        :error -> Map.delete(params, "value")
      end
    else
      params
    end
  end

  def put_login(params, _socket), do: params

  @doc "The errors of a form `field` as sentences, for the component's `errors`."
  @spec errors(Phoenix.HTML.FormField.t()) :: [String.t()]
  def errors(%Phoenix.HTML.FormField{errors: errors}),
    do: Enum.map(errors, &ApiaryWeb.CoreComponents.translate_error/1)

  @doc "The value id of the key the sign-in was started for, nil on a form."
  @spec key(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def key(socket), do: socket.assigns[:device] && socket.assigns.device.key

  @doc "Whether a sign-in has its code or its tokens, or is about to."
  @spec busy?(Phoenix.LiveView.Socket.t()) :: boolean
  def busy?(socket),
    do:
      match?(
        %{state: state} when state in [:starting, :code, :signed_in],
        socket.assigns[:device]
      )

  defp idle(nil), do: nil

  defp idle(kind) do
    if DeviceSignIn.available?(kind) do
      %{
        kind: kind,
        state: :idle,
        pid: nil,
        ref: nil,
        key: nil,
        user_code: nil,
        verification_url: nil,
        expires_at: nil,
        cause: nil
      }
    end
  end

  defp stop(%{pid: pid}) when is_pid(pid), do: DeviceSignIn.stop(pid)
  defp stop(_device), do: :ok

  ## The hooks

  defp event("device_sign_in", params, %{assigns: %{device: %{state: state} = device}} = socket)
       when state in @starts do
    stop(device)
    ref = make_ref()
    key = if is_binary(params["key"]) and params["key"] != "", do: params["key"]

    case DeviceSignIn.start(device.kind, ref) do
      {:ok, pid} ->
        {:halt,
         assign(socket, :device, %{
           idle(device.kind)
           | state: :starting,
             pid: pid,
             ref: ref,
             key: key
         })}

      {:error, :device_flow_unavailable} ->
        {:halt, assign(socket, :device, %{idle(device.kind) | state: :failed})}
    end
  end

  defp event("device_cancel", _params, %{assigns: %{device: %{} = device}} = socket) do
    stop(device)
    {:halt, assign(socket, :device, idle(device.kind))}
  end

  defp event(name, _params, socket) when name in ~w(device_sign_in device_cancel),
    do: {:halt, socket}

  defp event(_name, _params, socket), do: {:cont, socket}

  defp info({:device_sign_in, ref, event}, socket, signed_in) do
    case socket.assigns[:device] do
      %{ref: ^ref} = device ->
        socket = assign(socket, :device, advance(device, event))
        {:halt, if(event == :signed_in, do: signed_in.(socket), else: socket)}

      _stale ->
        {:halt, socket}
    end
  end

  defp info(_message, socket, _signed_in), do: {:cont, socket}

  defp advance(device, {:code, shown}),
    do: %{
      device
      | state: :code,
        user_code: shown.user_code,
        verification_url: shown.verification_url,
        expires_at: shown.expires_at
    }

  defp advance(device, :signed_in),
    do: %{device | state: :signed_in, user_code: nil, verification_url: nil, expires_at: nil}

  defp advance(device, {:ended, reason}) when reason in [:expired, :off],
    do: %{idle(device.kind) | state: reason, key: device.key}

  defp advance(device, {:ended, :failed, cause}),
    do: %{idle(device.kind) | state: :failed, key: device.key, cause: cause}
end
