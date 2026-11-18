defmodule Apiary.DeviceSignInStub do
  @moduledoc """
  The provider's side of a device sign-in in a test (`Apiary.ModelKeys.DeviceSignIn`): the
  addresses of an `oauth_device` on a test host, which the vendored description of the
  OpenAI subscription does not have yet, and a `Req.Test` stub of
  `Apiary.ModelKeys.LoginDevice` that answers the three calls as a script says. No call
  leaves the machine.
  """

  import ExUnit.Assertions

  alias Apiary.ModelKeys.{DeviceSignIn, LoginDevice}
  import Apiary.ModelKeysFixtures, only: [login_tokens: 1]

  @device %{
    "usercode_url" => "https://auth.example.test/device/usercode",
    "poll_url" => "https://auth.example.test/device/token",
    "verification_url" => "https://auth.example.test/device",
    "redirect_uri" => "https://auth.example.test/device/callback"
  }

  @doc "The `oauth_device` of the test provider."
  def device, do: @device

  @doc """
  Gives the keys of the provider `kind` the test `oauth_device` in the calling process and
  the processes it starts, and sets the script `opts` (`script/1`).
  """
  def put(opts \\ [], kind \\ "openai-subscription") do
    DeviceSignIn.put_test_device(kind, @device)
    script(opts)
  end

  @doc """
  Sets what the provider answers, in the calling process and the processes it starts:

    * `:code`: the code of the first call, `"7QKD-M4TPX"`;
    * `:expires_at`: when the code stops working, a DateTime, 15 minutes from now;
    * `:usercode`: the status of the first call when it is not 200, such as `404`;
    * `:pending`: how many polls answer 403 before the approval, 1; `:never` for no approval;
    * `:poll`: the status of every poll when it is not a 403 or a 200, such as `500`;
    * `:exchange`: the status of the code exchange when it is not 200;
    * `:tokens`: the tokens of the exchange (`Apiary.ModelKeysFixtures.login_tokens/1`);
    * `:hold`: when true, every poll answers 403 until the test calls `approve/0`;
    * `:interval`: what the first call sends as `interval`, `"5"`.

  The stub counts the calls it gets (`calls/1`) and sends the test process
  `{:device_call, path, body}` for each.
  """
  def script(opts \\ []) do
    counts = :counters.new(3, [])
    tokens = Keyword.get_lazy(opts, :tokens, fn -> login_tokens(tag: "device") end)
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 900))
    pending = Keyword.get(opts, :pending, 1)
    code = Keyword.get(opts, :code, "7QKD-M4TPX")
    approved = :atomics.new(1, [])
    Process.put({__MODULE__, :counts}, counts)
    Process.put({__MODULE__, :approved}, approved)
    test = self()

    Req.Test.stub(LoginDevice, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:device_call, conn.request_path, body})

      case conn.request_path do
        "/device/usercode" ->
          :counters.add(counts, 1, 1)

          case Keyword.get(opts, :usercode, 200) do
            200 ->
              Req.Test.json(conn, %{
                "device_auth_id" => "device-auth-fixture",
                "user_code" => code,
                "interval" => Keyword.get(opts, :interval, "5"),
                "expires_at" => DateTime.to_iso8601(expires_at)
              })

            status ->
              conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => "nope"})
          end

        "/device/token" ->
          :counters.add(counts, 2, 1)
          answered = :counters.get(counts, 2)

          cond do
            Keyword.has_key?(opts, :poll) ->
              conn |> Plug.Conn.put_status(opts[:poll]) |> Req.Test.json(%{"error" => "nope"})

            Keyword.get(opts, :hold, false) and :atomics.get(approved, 1) == 0 ->
              conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => "pending"})

            pending == :never or (not Keyword.get(opts, :hold, false) and answered <= pending) ->
              conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => "pending"})

            true ->
              Req.Test.json(conn, %{
                "authorization_code" => "authorization-code-fixture",
                "code_challenge" => "challenge-fixture",
                "code_verifier" => "verifier-fixture"
              })
          end

        "/oauth/token" ->
          :counters.add(counts, 3, 1)

          case Keyword.get(opts, :exchange, 200) do
            200 ->
              Req.Test.json(conn, %{
                "access_token" => tokens.access_token,
                "refresh_token" => tokens.refresh_token,
                "id_token" => tokens.id_token,
                "expires_in" => 864_000
              })

            status ->
              conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => "nope"})
          end
      end
    end)

    tokens
  end

  @doc "Lets the polls of a script with `hold: true` get the approval."
  def approve, do: :atomics.put(Process.get({__MODULE__, :approved}), 1, 1)

  @doc "How many calls the script got: `:code`, `:poll` or `:exchange`."
  def calls(which) do
    counts = Process.get({__MODULE__, :counts})
    :counters.get(counts, Map.fetch!(%{code: 1, poll: 2, exchange: 3}, which))
  end

  @doc "Calls `fun` every 20 ms until it returns without a failed assertion, for up to 3 s."
  def eventually(fun, tries \\ 150) do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if tries > 0 do
        Process.sleep(20)
        eventually(fun, tries - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc "Asserts that the process `pid` has ended, within 3 s."
  def assert_ended(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 3_000
  end
end
